open Lwt

let src =
  let src = Logs.Src.create "usernet" ~doc:"Mirage TCP/IP <-> socket proxy" in
  Logs.Src.set_level src (Some Logs.Info);
  src

module Log = (val Logs.src_log src : Logs.LOG)

module IPMap = Map.Make(Ipaddr.V4)


let default_peer = "192.168.65.2"
let default_host = "192.168.65.1"
(* random MAC from https://www.hellion.org.uk/cgi-bin/randmac.pl *)
let default_server_macaddr = Macaddr.of_string_exn "F6:16:36:BC:F9:C6"
let default_dns_extra = []

(* When forwarding TCP, the connection is proxied so the MTU/MSS is link-local.
   When forwarding UDP, the datagram on the internal link is the same size as
   the corresponding datagram on the external link, so we have to be careful
   to respect the Do Not Fragment bit. *)
let safe_outgoing_mtu = 1452 (* packets above this size with DNF set will get ICMP errors *)

(* The default MTU is limited by the maximum message size on a Hyper-V socket.
   On currently available windows versions, we need to stay below 8192 bytes *)
let default_mtu = 8000 (* used for the virtual ethernet link *)

let log_exception_continue description f =
  Lwt.catch
    (fun () -> f ())
    (fun e ->
       Log.debug (fun f -> f "%s: caught %s" description (Printexc.to_string e));
       Lwt.return ()
    )

module Infix = struct
  let ( >>= ) m f = m >>= function
    | `Ok x -> f x
    | `Error x -> Lwt.return (`Error x)
end

let or_failwith name m =
  m >>= function
  | `Error _ -> Lwt.fail (Failure (Printf.sprintf "Failed to connect %s device" name))
  | `Ok x -> Lwt.return x

let or_failwith_result name m =
  m >>= function
  | Result.Error _ -> Lwt.fail (Failure (Printf.sprintf "Failed to connect %s device" name))
  | Result.Ok x -> Lwt.return x

let or_error name m =
  m >>= function
  | `Error _ -> Lwt.return (`Error (`Msg (Printf.sprintf "Failed to connect %s device" name)))
  | `Ok x -> Lwt.return (`Ok x)

let restart_on_change name to_string values =
  Active_config.tl values
  >>= fun values ->
  let v = Active_config.hd values in
  Log.info (fun f -> f "%s changed to %s in the database: restarting" name (to_string v));
  exit 1

type pcap = (string * int64 option) option

let print_pcap = function
  | None -> "disabled"
  | Some (file, None) -> "capturing to " ^ file ^ " with no limit"
  | Some (file, Some limit) -> "capturing to " ^ file ^ " but limited to " ^ (Int64.to_string limit)

type config = {
  server_macaddr: Macaddr.t;
  peer_ip: Ipaddr.V4.t;
  local_ip: Ipaddr.V4.t;
  extra_dns_ip: Ipaddr.V4.t list;
  get_domain_search: unit -> string list;
  get_domain_name: unit -> string;
  mtu: int;
}

module Make(Config: Active_config.S)(Vmnet: Sig.VMNET)(Dns_policy: Sig.DNS_POLICY)(Host: Sig.HOST)(Vnet : Vnetif.BACKEND) = struct
  (* module Tcpip_stack = Tcpip_stack.Make(Vmnet)(Host.Time) *)

  module Filteredif = Filter.Make(Vmnet)
  module Netif = Capture.Make(Filteredif)
  module Recorder = (Netif: Sig.RECORDER with type t = Netif.t)
  module Switch = Mux.Make(Netif)
  module Dhcp = Dhcp.Make(Switch)

  (* This ARP implementation will respond to the VM: *)
  module Global_arp_ethif = Ethif.Make(Switch)
  module Global_arp = Arp.Make(Global_arp_ethif)

  (* This stack will attach to a switch port and represent a single remote IP *)
  module Stack_ethif = Ethif.Make(Switch.Port)
  module Stack_arpv4 = Arp.Make(Stack_ethif)
  module Stack_ipv4 = Ipv4.Make(Stack_ethif)(Stack_arpv4)
  module Stack_icmpv4 = Icmpv4.Make(Stack_ipv4)
  module Stack_tcp_wire = Tcp.Wire.Make(Stack_ipv4)
  module Stack_udp = Udp.Make(Stack_ipv4)
  module Stack_tcp = struct
    include Tcp.Flow.Make(Stack_ipv4)(Host.Time)(Clock)(Random)
    let shutdown_read _flow =
      (* No change to the TCP PCB: all this means is that I've
         got my finders in my ears and am nolonger listening to
         what you say. *)
      Lwt.return ()
    let shutdown_write = close
  end

  module Dns_forwarder = Hostnet_dns.Make(Stack_ipv4)(Stack_udp)(Stack_tcp)(Host.Sockets)(Host.Time)(Recorder)
  module Udp_nat = Hostnet_udp.Make(Host.Sockets)(Host.Time)

  (* Global variable containing the global DNS configuration *)
  let dns =
    let ip = Ipaddr.V4 (Ipaddr.V4.of_string_exn default_host) in
    let local_address = { Dns_forward.Config.Address.ip; port = 0 } in
    ref (Dns_forwarder.create ~local_address @@ Dns_policy.config ())

  let is_dns = let open Frame in function
    | Ethernet { payload = Ipv4 { payload = Udp { src = 53; _ }; _ }; _ }
    | Ethernet { payload = Ipv4 { payload = Udp { dst = 53; _ }; _ }; _ }
    | Ethernet { payload = Ipv4 { payload = Tcp { src = 53; _ }; _ }; _ }
    | Ethernet { payload = Ipv4 { payload = Tcp { dst = 53; _ }; _ }; _ } -> true
    | _ -> false

  let string_of_id id =
    Printf.sprintf "TCP %s:%d > %s:%d"
      (Ipaddr.V4.to_string id.Stack_tcp_wire.dest_ip) id.Stack_tcp_wire.dest_port
      (Ipaddr.V4.to_string id.Stack_tcp_wire.local_ip) id.Stack_tcp_wire.local_port

  module Tcp = struct

    module Id = struct
      module M = struct
        type t = Stack_tcp_wire.id
        let compare
            { Stack_tcp_wire.local_ip = local_ip1; local_port = local_port1; dest_ip = dest_ip1; dest_port = dest_port1 }
            { Stack_tcp_wire.local_ip = local_ip2; local_port = local_port2; dest_ip = dest_ip2; dest_port = dest_port2 } =
          let dest_ip' = Ipaddr.V4.compare dest_ip1 dest_ip2 in
          let local_ip' = Ipaddr.V4.compare local_ip1 local_ip2 in
          let dest_port' = compare dest_port1 dest_port2 in
          let local_port' = compare local_port1 local_port2 in
          if dest_port' <> 0
          then dest_port'
          else if dest_ip' <> 0
          then dest_ip'
          else if local_ip' <> 0
          then local_ip'
          else local_port'
      end
      include M
      module Set = Set.Make(M)
      module Map = Map.Make(M)
    end

    module Flow = struct
      (** An established flow *)

      type t = {
        id: Stack_tcp_wire.id;
        mutable socket: Host.Sockets.Stream.Tcp.flow option;
        mutable last_active_time: float;
      }

      let to_string t =
        Printf.sprintf "%s socket = %s last_active_time = %.1f"
          (string_of_id t.id)
          (match t.socket with None -> "closed" | _ -> "open")
          (Unix.gettimeofday ())

      (* Global table of active flows *)
      let all : t Id.Map.t ref = ref Id.Map.empty

      let filesystem =
        Vfs.Dir.of_list
          (fun () ->
             Vfs.ok (
               Id.Map.fold
                 (fun _ t acc -> Vfs.Inode.dir (to_string t) Vfs.Dir.empty :: acc)
                 !all []
             )
          )

      let create id socket =
        let socket = Some socket in
        let last_active_time = Unix.gettimeofday () in
        let t = { id; socket; last_active_time } in
        all := Id.Map.add id t !all;
        t
      let remove id =
        all := Id.Map.remove id !all
      let touch id =
        if Id.Map.mem id !all
        then (Id.Map.find id !all).last_active_time <- Unix.gettimeofday ()
    end
  end

  module Endpoint = struct

    type t = {
      recorder:                 Recorder.t;
      netif:                    Switch.Port.t;
      ethif:                    Stack_ethif.t;
      arp:                      Stack_arpv4.t;
      ipv4:                     Stack_ipv4.t;
      icmpv4:                   Stack_icmpv4.t;
      udp4:                     Stack_udp.t;
      tcp4:                     Stack_tcp.t;
      mutable pending:          Tcp.Id.Set.t;
      mutable last_active_time: float;
    }
    (** A generic TCP/IP endpoint *)

    let touch t =
      t.last_active_time <- Unix.gettimeofday ()

    let create recorder switch arp_table ip mtu =
      let netif = Switch.port switch ip in
      let open Infix in
      or_error "Stack_ethif.connect" @@ Stack_ethif.connect ~mtu netif
      >>= fun ethif ->
      or_error "Stack_arpv4.connect" @@ Stack_arpv4.connect ~table:arp_table ethif
      >>= fun arp ->
      or_error "Stack_ipv4.connect" @@ Stack_ipv4.connect ethif arp
      >>= fun ipv4 ->
      or_error "Stack_icmpv4.connect" @@ Stack_icmpv4.connect ipv4
      >>= fun icmpv4 ->
      or_error "Stack_udp.connect" @@ Stack_udp.connect ipv4
      >>= fun udp4 ->
      or_error "Stack_tcp.connect" @@ Stack_tcp.connect ipv4
      >>= fun tcp4 ->

      let open Lwt.Infix in
      Stack_ipv4.set_ip ipv4 ip (* I am the destination *)
      >>= fun () ->
      Stack_ipv4.set_ip_netmask ipv4 Ipaddr.V4.unspecified (* 0.0.0.0 *)
      >>= fun () ->
      Stack_ipv4.set_ip_gateways ipv4 [ ]
      >>= fun () ->

      let pending = Tcp.Id.Set.empty in
      let last_active_time = Unix.gettimeofday () in
      let tcp_stack = { recorder; netif; ethif; arp; ipv4; icmpv4; udp4; tcp4; pending; last_active_time } in
      Lwt.return (`Ok tcp_stack)

    let intercept_tcp_syn t ~id ~syn on_syn_callback (buf: Cstruct.t) =
      if syn then begin
        if Tcp.Id.Set.mem id t.pending then begin
          (* This can happen if the `connect` blocks for a few seconds *)
          Log.debug (fun f -> f "%s: connection in progress, ignoring duplicate SYN" (string_of_id id));
          Lwt.return_unit
        end else begin
          t.pending <- Tcp.Id.Set.add id t.pending;
          Lwt.finalize
            (fun () ->
               on_syn_callback ()
               >>= fun listeners ->
               Stack_tcp.input t.tcp4 ~listeners ~src:id.Stack_tcp_wire.dest_ip ~dst:id.Stack_tcp_wire.local_ip buf
            ) (fun () ->
                t.pending <- Tcp.Id.Set.remove id t.pending;
                Lwt.return_unit;
              )
        end
      end else begin
        Tcp.Flow.touch id;
        (* non-SYN packets are injected into the stack as normal *)
        Stack_tcp.input t.tcp4 ~listeners:(fun _ -> None) ~src:id.Stack_tcp_wire.dest_ip ~dst:id.Stack_tcp_wire.local_ip buf
      end

    let input_tcp t ~id ~syn (ip, port) (buf: Cstruct.t) =
      intercept_tcp_syn t ~id ~syn
        (fun () ->
          Host.Sockets.Stream.Tcp.connect (ip, port)
          >>= function
          | Result.Error (`Msg m) ->
            Log.debug (fun f -> f "%s:%d: failed to connect, sending RST: %s" (Ipaddr.to_string ip) port m);
            Lwt.return (fun _ -> None)
          | Result.Ok socket ->
            let t = Tcp.Flow.create id socket in
            let listeners port =
              Log.debug (fun f -> f "%s:%d handshake complete" (Ipaddr.to_string ip) port);
              Some (fun flow ->
                match t.Tcp.Flow.socket with
                  | None ->
                    Log.err (fun f -> f "%s callback called on closed socket" (Tcp.Flow.to_string t));
                    Lwt.return_unit
                  | Some socket ->
                    Lwt.finalize
                      (fun () ->
                         Mirage_flow.proxy (module Clock) (module Stack_tcp) flow (module Host.Sockets.Stream.Tcp) socket ()
                         >>= function
                         | `Error (`Msg m) ->
                           Log.debug (fun f -> f "%s proxy failed with %s" (Tcp.Flow.to_string t) m);
                           Lwt.return_unit
                         | `Ok (_l_stats, _r_stats) ->
                           Lwt.return_unit
                      ) (fun () ->
                          Log.debug (fun f -> f "closing flow %s" (string_of_id t.Tcp.Flow.id));
                          t.Tcp.Flow.socket <- None;
                          Tcp.Flow.remove t.Tcp.Flow.id;
                          Host.Sockets.Stream.Tcp.close socket
                          >>= fun () ->
                          Lwt.return_unit
                        )
                  )  in
            Lwt.return listeners
        ) buf

    (* Send an ICMP destination reachable message in response to the given
       packet. This can be used to indicate the packet would have been fragmented
       when the do-not-fragment flag is set. *)
    let send_icmp_dst_unreachable t ~src ~dst ~src_port ~dst_port ~ihl raw =
      let would_fragment ~ip_header ~ip_payload =
        let open Icmpv4_wire in
        let header = Cstruct.create sizeof_icmpv4 in
        set_icmpv4_ty header 0x03;
        set_icmpv4_code header 0x04;
        set_icmpv4_csum header 0x0000;
        (* this field is unused for icmp destination unreachable *)
        set_icmpv4_id header 0x00;
        set_icmpv4_seq header safe_outgoing_mtu;
        let icmp_payload = match ip_payload with
          | Some ip_payload ->
            if (Cstruct.len ip_payload > 8) then begin
              let ip_payload = Cstruct.sub ip_payload 0 8 in
              Cstruct.append ip_header ip_payload
            end else Cstruct.append ip_header ip_payload
          | None -> ip_header
        in
        set_icmpv4_csum header
          (Tcpip_checksum.ones_complement_list [ header;
                                                 icmp_payload ]);
        let icmp_packet = Cstruct.append header icmp_payload in
        icmp_packet
      in
      let ethernet_frame, len = Stack_ipv4.allocate_frame t.ipv4 ~dst:src ~proto:`ICMP in
      let ethernet_ip_hdr = Cstruct.sub ethernet_frame 0 len in

      let reply = would_fragment
          ~ip_header:(Cstruct.sub raw 0 (ihl * 4))
          ~ip_payload:(Some (Cstruct.sub raw (ihl * 4) 8)) in
      (* Rather than silently unset the do not fragment bit, we
         respond with an ICMP error message which will
         hopefully prompt the other side to send messages we
         can forward *)
      Log.err (fun f -> f
                  "Sending icmp-dst-unreachable in response to UDP %s:%d -> %s:%d with DNF set IPv4 len %d"
                  (Ipaddr.V4.to_string src) src_port
                  (Ipaddr.V4.to_string dst) dst_port
                  len);
      Stack_ipv4.writev t.ipv4 ethernet_ip_hdr [ reply ];
  end

  type t = {
    l2_switch: Vnet.t;
    l2_client_id: Vnet.id;
    after_disconnect: unit Lwt.t;
    interface: Netif.t;
    switch: Switch.t;
    mutable endpoints: Endpoint.t IPMap.t;
    endpoints_m: Lwt_mutex.t;
    udp_nat: Udp_nat.t;
  }

  let after_disconnect t = t.after_disconnect

  open Frame

  module Local = struct
    type t = {
      endpoint: Endpoint.t;
      udp_nat: Udp_nat.t;
      dns_ips: Ipaddr.V4.t list;
    }
    (** Represents the local machine including NTP and DNS servers *)

    (** Handle IPv4 datagrams by proxying them to a remote system *)
    let input_ipv4 t ipv4 = match ipv4 with
      (* Respond to ICMP *)
      | Ipv4 { raw; payload = Icmp _; _ } ->
        let none ~src:_ ~dst:_ _ = Lwt.return_unit in
        let default ~proto ~src ~dst buf = match proto with
          | 1 (* ICMP *) ->
            Stack_icmpv4.input t.endpoint.Endpoint.icmpv4 ~src ~dst buf
          | _ ->
            Lwt.return_unit in
        Stack_ipv4.input t.endpoint.Endpoint.ipv4 ~tcp:none ~udp:none ~default raw
      (* UDP on port 53 -> DNS forwarder *)
      | Ipv4 { src; dst; payload = Udp { src = src_port; dst = 53; payload = Payload payload; _ }; _ } ->
        let udp = t.endpoint.Endpoint.udp4 in
        !dns >>= fun t ->
        Dns_forwarder.handle_udp ~t ~udp ~src ~dst ~src_port payload
      (* TCP to port 53 -> DNS forwarder *)
      | Ipv4 { src; dst; payload = Tcp { src = src_port; dst = 53; syn; raw; payload = Payload _; _ }; _ } ->
        let id = { Stack_tcp_wire.local_port = 53; dest_ip = src; local_ip = dst; dest_port = src_port } in
        Endpoint.intercept_tcp_syn t.endpoint ~id ~syn
          (fun () ->
            !dns >>= fun t ->
            Dns_forwarder.handle_tcp ~t
          ) raw
      (* UDP to port 123: localhost NTP *)
      | Ipv4 { src; payload = Udp { src = src_port; dst = 123; payload = Payload payload; _ }; _ } ->
        let localhost = Ipaddr.V4.localhost in
        Log.debug (fun f -> f "UDP/123 request from port %d -- sending it to %a:%d" src_port Ipaddr.V4.pp_hum localhost 123);
        let datagram = { Hostnet_udp.src = Ipaddr.V4 src, src_port; dst = Ipaddr.V4 localhost, 123; payload } in
        Udp_nat.input ~t:t.udp_nat ~datagram ()
      (* UDP to any other port: localhost *)
      | Ipv4 { src; dst; ihl; dnf; raw; payload = Udp { src = src_port; dst = dst_port; len; payload = Payload payload; _ }; _ } ->
        let description = Printf.sprintf "%s:%d -> %s:%d"
            (Ipaddr.V4.to_string src) src_port (Ipaddr.V4.to_string dst) dst_port in
        if Cstruct.len payload < len then begin
          Log.err (fun f -> f "%s: dropping because reported len %d actual len %d" description len (Cstruct.len payload));
          Lwt.return_unit
        end else if dnf && (Cstruct.len payload > safe_outgoing_mtu) then begin
          Endpoint.send_icmp_dst_unreachable t.endpoint ~src ~dst ~src_port ~dst_port ~ihl raw
        end else begin
          (* [1] For UDP to our local address, rewrite the destination to localhost.
             This is the inverse of the rewrite below[2] *)
          let datagram = { Hostnet_udp.src = Ipaddr.V4 src, src_port; dst = Ipaddr.(V4 V4.localhost), dst_port; payload } in
          Udp_nat.input ~t:t.udp_nat ~datagram ()
        end
      (* TCP to local ports *)
      | Ipv4 { src; dst; payload = Tcp { src = src_port; dst = dst_port; syn; raw; payload = Payload _; _ }; _ } ->
        let id = { Stack_tcp_wire.local_port = dst_port; dest_ip = src; local_ip = dst; dest_port = src_port } in
        Endpoint.input_tcp t.endpoint ~id ~syn (Ipaddr.V4 Ipaddr.V4.localhost, dst_port) raw
      | _ ->
        Lwt.return_unit

    let create endpoint udp_nat dns_ips =
      let tcp_stack = { endpoint; udp_nat; dns_ips } in
      let open Lwt.Infix in
      (* Wire up the listeners to receive future packets: *)
      Switch.Port.listen endpoint.Endpoint.netif
        (fun buf ->
           let open Frame in
           match parse [ buf ] with
           | Ok (Ethernet { payload = Ipv4 ipv4; _ }) ->
             Endpoint.touch endpoint;
             input_ipv4 tcp_stack (Ipv4 ipv4)
           | _ ->
              Lwt.return_unit
        )
      >>= fun () ->

      Lwt.return (`Ok tcp_stack)

  end

  module Remote = struct

    type t = {
      endpoint:        Endpoint.t;
      udp_nat:         Udp_nat.t;
    }
    (** Represents a remote system by proxying data to and from sockets *)

    (** Handle IPv4 datagrams by proxying them to a remote system *)
    let input_ipv4 t ipv4 = match ipv4 with
      (* Respond to ICMP *)
      | Ipv4 { raw; payload = Icmp _; _ } ->
        let none ~src:_ ~dst:_ _ = Lwt.return_unit in
        let default ~proto ~src ~dst buf = match proto with
          | 1 (* ICMP *) ->
            Stack_icmpv4.input t.endpoint.Endpoint.icmpv4 ~src ~dst buf
          | _ ->
            Lwt.return_unit in
        Stack_ipv4.input t.endpoint.Endpoint.ipv4 ~tcp:none ~udp:none ~default raw
      | Ipv4 { src = dest_ip; dst = local_ip; payload = Tcp { src = dest_port; dst = local_port; syn; raw; _ }; _ } ->
        let id = { Stack_tcp_wire.local_port; dest_ip; local_ip; dest_port } in
        Endpoint.input_tcp t.endpoint ~id ~syn (Ipaddr.V4 local_ip, local_port) raw
      | Ipv4 { src; dst; ihl; dnf; raw; payload = Udp { src = src_port; dst = dst_port; len; payload = Payload payload; _ }; _ } ->
        let description = Printf.sprintf "%s:%d -> %s:%d"
            (Ipaddr.V4.to_string src) src_port (Ipaddr.V4.to_string dst) dst_port in
        if Cstruct.len payload < len then begin
          Log.err (fun f -> f "%s: dropping because reported len %d actual len %d" description len (Cstruct.len payload));
          Lwt.return_unit
        end else if dnf && (Cstruct.len payload > safe_outgoing_mtu) then begin
          Endpoint.send_icmp_dst_unreachable t.endpoint ~src ~dst ~src_port ~dst_port ~ihl raw
        end else begin
          let datagram = { Hostnet_udp.src = Ipaddr.V4 src, src_port; dst = Ipaddr.V4 dst, dst_port; payload } in
          Udp_nat.input ~t:t.udp_nat ~datagram ()
        end
      | _ ->
        Lwt.return_unit

    let create endpoint udp_nat =
      let tcp_stack = { endpoint; udp_nat } in
      let open Lwt.Infix in
      (* Wire up the listeners to receive future packets: *)
      Switch.Port.listen endpoint.Endpoint.netif
        (fun buf ->
           let open Frame in
           match parse [ buf ] with
           | Ok (Ethernet { payload = Ipv4 ipv4; _ }) ->
             Endpoint.touch endpoint;
             input_ipv4 tcp_stack (Ipv4 ipv4)
           | _ ->
            Lwt.return_unit
        )
      >>= fun () ->

      Lwt.return (`Ok tcp_stack)
  end

  let filesystem t =
    let endpoints =
      Vfs.Dir.of_list
        (fun () ->
           Vfs.ok (
             IPMap.fold
               (fun ip t acc ->
                  let txt = Printf.sprintf "%s last_active_time = %.1f" (Ipaddr.V4.to_string ip) t.Endpoint.last_active_time in
                  Vfs.Inode.dir txt Vfs.Dir.empty :: acc)
               t.endpoints []
           )
        ) in
    Vfs.Dir.of_list
      (fun () ->
         Vfs.ok [
           (* could replace "connections" with "flows" *)
           Vfs.Inode.dir "connections" Host.Sockets.connections;
           Vfs.Inode.dir "capture" @@ Netif.filesystem t.interface;
           Vfs.Inode.dir "flows" Tcp.Flow.filesystem;
           Vfs.Inode.dir "endpoints" endpoints;
           Vfs.Inode.dir "ports" @@ Switch.filesystem t.switch;
         ]
      )

  let diagnostics t flow =
    let module C = Channel.Make(Host.Sockets.Stream.Unix) in
    let module Writer = Tar.HeaderWriter(Lwt)(struct
      type out_channel = C.t
      type 'a t = 'a Lwt.t
      let really_write oc buf =
        C.write_buffer oc buf;
        C.flush oc
    end) in
    let c = C.create flow in

    (* Operator which logs Vfs errors and returns *)
    let (>>?=) m f = m >>= function
      | Result.Ok x -> f x
      | Result.Error err ->
        Log.err (fun l -> l "diagnostics error: %a" Vfs.Error.pp err);
        Lwt.return_unit in

    let rec tar pwd dir =
      Vfs.Dir.ls dir
      >>?= fun inodes ->
      Lwt_list.iter_s
        (fun inode ->
          match Vfs.Inode.kind inode with
          | `Dir dir ->
            tar (Filename.concat pwd @@ Vfs.Inode.basename inode) dir
          | `File file ->
            (* Buffer the whole file temporarily in memory so we can calculate
               the exact length needed by the tar header. Note the `stat`
               won't be accurate because the file can change after we open it.
               If there was an `fstat` API this could be fixed. *)
            Vfs.File.open_ file
            >>?= fun fd ->
            let copy () =
              let fragments = ref [] in
              let rec aux offset =
                let count = 1048576 in
                Vfs.File.read fd ~offset ~count
                >>?= fun buf ->
                fragments := buf :: !fragments;
                let len = Int64.of_int @@ Cstruct.len buf in
                if len = 0L
                then Lwt.return_unit
                else aux (Int64.add offset len) in
              aux 0L
              >>= fun () ->
              Lwt.return (List.rev !fragments) in
            copy ()
            >>= fun fragments ->
            let length = List.fold_left (+) 0 (List.map Cstruct.len fragments) in
            let header = Tar.Header.make (Filename.concat pwd @@ Vfs.Inode.basename inode) (Int64.of_int length) in
            Writer.write header c
            >>= fun () ->
            List.iter (C.write_buffer c) fragments;
            C.write_buffer c (Tar.Header.zero_padding header);
            C.flush c
        ) inodes in
    tar "" (filesystem t)
    >>= fun () ->
    C.write_buffer c Tar.Header.zero_block;
    C.write_buffer c Tar.Header.zero_block;
    C.flush c

  module Debug = struct
    let get_nat_table_size t = Udp_nat.get_nat_table_size t.udp_nat
  end

  (* If no traffic is received for 5 minutes, delete the endpoint and
     the switch port. *)
  let rec delete_unused_endpoints t () =
    Host.Time.sleep 30.
    >>= fun () ->
    Lwt_mutex.with_lock t.endpoints_m
      (fun () ->
         let now = Unix.gettimeofday () in
         let old_ips = IPMap.fold (fun ip endpoint acc ->
             let age = now -. endpoint.Endpoint.last_active_time in
             if age > 300.0 then ip :: acc else acc
           ) t.endpoints [] in
         List.iter (fun ip ->
             Switch.remove t.switch ip;
             t.endpoints <- IPMap.remove ip t.endpoints
           ) old_ips;
         Lwt.return_unit
      )
    >>= fun () ->
    delete_unused_endpoints t ()

  let connect x l2_switch l2_client_id server_macaddr peer_ip local_ip extra_dns_ip mtu get_domain_search get_domain_name =

    let client_macaddr = Vnet.mac l2_switch l2_client_id in

    let valid_subnets = [ Ipaddr.V4.Prefix.global ] in
    let valid_sources = [ Ipaddr.V4.of_string_exn "0.0.0.0" ] in

    or_failwith "filter" @@ Filteredif.connect ~valid_subnets ~valid_sources x
    >>= fun (filteredif: Filteredif.t) ->
    or_failwith "capture" @@ Netif.connect filteredif
    >>= fun interface ->
    Dns_forwarder.set_recorder interface;

    let kib = 1024 in
    (* Capture 256 KiB of DNS traffic *)
    Netif.add_match ~t:interface ~name:"dns.pcap" ~limit:(256 * kib) ~snaplen:1500 ~predicate:is_dns;

    Switch.connect interface
    >>= fun switch ->

    (* Serve a static ARP table *)
    let arp_table = [
      peer_ip, client_macaddr;
      local_ip, server_macaddr;
    ] @ (List.map (fun ip -> ip, server_macaddr) extra_dns_ip) in
    or_failwith "arp_ethif" @@ Global_arp_ethif.connect switch
    >>= fun global_arp_ethif ->
    or_failwith "arp" @@ Global_arp.connect ~table:arp_table global_arp_ethif
    >>= fun arp ->

    (* Listen on local IPs *)
    let local_ips = local_ip :: extra_dns_ip in

    let dhcp = Dhcp.make ~client_macaddr ~server_macaddr ~peer_ip ~local_ip
      ~extra_dns_ip ~get_domain_search ~get_domain_name switch in

    let endpoints = IPMap.empty in
    let endpoints_m = Lwt_mutex.create () in
    let udp_nat = Udp_nat.create () in
    let t = {
      l2_switch;
      l2_client_id;
      after_disconnect = Vmnet.after_disconnect x;
      interface;
      switch;
      endpoints;
      endpoints_m;
      udp_nat;
    } in
    Lwt.async @@ delete_unused_endpoints t;

    let find_endpoint ip =
      Lwt_mutex.with_lock t.endpoints_m
        (fun () ->
          if IPMap.mem ip t.endpoints
          then Lwt.return (`Ok (IPMap.find ip t.endpoints))
          else begin
            let open Infix in
            Endpoint.create interface switch arp_table ip mtu
            >>= fun endpoint ->
            t.endpoints <- IPMap.add ip endpoint t.endpoints;
            Lwt.return (`Ok endpoint)
          end
        ) in

    (* Send a UDP datagram *)
    let send_reply = function
      | { Hostnet_udp.src = Ipaddr.V4 src, src_port; dst = Ipaddr.V4 dst, dst_port; payload } ->
        (* [2] If the source address is localhost on the Mac, rewrite it to the
           virtual IP. This is the inverse of the rewrite above[1] *)
        let src =
          if Ipaddr.V4.compare src Ipaddr.V4.localhost = 0
          then local_ip
          else src in
        begin
          find_endpoint src
          >>= function
          | `Error (`Msg m) ->
            Log.err (fun f -> f "Failed to create an endpoint for %s: %s" (Ipaddr.V4.to_string dst) m);
            Lwt.return_unit
          | `Ok endpoint ->
            Stack_udp.write ~source_port:src_port ~dest_ip:dst ~dest_port:dst_port endpoint.Endpoint.udp4 payload
        end
      | { Hostnet_udp.src = src, src_port; dst = dst, dst_port; _ } ->
        Log.err (fun f -> f "Failed to send non-IPv4 UDP datagram %s:%d -> %s:%d" (Ipaddr.to_string src) src_port (Ipaddr.to_string dst) dst_port);
        Lwt.return_unit in

    Udp_nat.set_send_reply ~t:udp_nat ~send_reply;

    (* Add a listener which looks for new flows *)
    Switch.listen switch
      (fun buf ->
         let open Frame in
         match parse [ buf ] with
         | Ok (Ethernet { payload = Ipv4 { payload = Udp { dst = 67; _ }; _ }; _ })
         | Ok (Ethernet { payload = Ipv4 { payload = Udp { dst = 68; _ }; _ }; _ }) ->
           Dhcp.callback dhcp buf
         | Ok (Ethernet { payload = Arp { op = `Request }; _ }) ->
           (* Arp.input expects only the ARP packet, with no ethernet header prefix *)
           Global_arp.input arp (Cstruct.shift buf Wire_structs.sizeof_ethernet)
         | Ok (Ethernet { payload = Ipv4 ({ dst; _ } as ipv4 ); _ }) ->
           (* For any new IP destination, create a stack to proxy for the remote system *)
           if List.mem dst local_ips then begin
             begin
               let open Infix in
               find_endpoint dst
               >>= fun endpoint ->
               Log.debug (fun f -> f "creating local TCP/IP proxy for %s" (Ipaddr.V4.to_string dst));
               Local.create endpoint udp_nat local_ips
             end >>= function
             | `Error (`Msg m) ->
               Log.err (fun f -> f "Failed to create a TCP/IP stack: %s" m);
               Lwt.return_unit
             | `Ok tcp_stack ->
               (* inject the ethernet frame into the new stack *)
               Local.input_ipv4 tcp_stack (Ipv4 ipv4)
           end else begin
             begin
               let open Infix in
               find_endpoint dst
               >>= fun endpoint ->
               Log.debug (fun f -> f "create remote TCP/IP proxy for %s" (Ipaddr.V4.to_string dst));
               Remote.create endpoint udp_nat
             end >>= function
             | `Error (`Msg m) ->
               Log.err (fun f -> f "Failed to create a TCP/IP stack: %s" m);
               Lwt.return_unit
             | `Ok tcp_stack ->
               (* inject the ethernet frame into the new stack *)
               Remote.input_ipv4 tcp_stack (Ipv4 ipv4)
           end
         | _ ->
           Lwt.return_unit
      )
    >>= fun () ->

    Log.info (fun f -> f "TCP/IP ready");
    Lwt.return t

  let create config =
    let driver = [ "com.docker.driver.amd64-linux" ] in

    let max_connections_path = driver @ [ "slirp"; "max-connections" ] in
    Config.string_option config max_connections_path
    >>= fun string_max_connections ->
    let parse_max = function
      | None -> Lwt.return None
      | Some x -> Lwt.return (
          try Some (int_of_string @@ String.trim x)
          with _ ->
            Log.err (fun f -> f "Failed to parse slirp/max-connections value: '%s'" x);
            None
        ) in
    Active_config.map parse_max string_max_connections
    >>= fun max_connections ->
    let rec monitor_max_connections_settings settings =
      begin match Active_config.hd settings with
        | None ->
          Log.info (fun f -> f "remove connection limit");
          Host.Sockets.set_max_connections None
        | Some limit ->
          Log.info (fun f -> f "updating connection limit to %d" limit);
          Host.Sockets.set_max_connections (Some limit)
      end;
      Active_config.tl settings
      >>= fun settings ->
      monitor_max_connections_settings settings in
    Lwt.async (fun () -> log_exception_continue "monitor max connections settings" (fun () -> monitor_max_connections_settings max_connections));

    (* TODO Don't hardcode this *)
    let server_macaddr = default_server_macaddr in

    (* Watch for DNS server overrides *)
    let domain_search = ref [] in
    let get_domain_search () = !domain_search in
    let dns_path = driver @ [ "slirp"; "dns" ] in
    Config.string_option config dns_path
    >>= fun string_dns_settings ->
    Active_config.map
      (function
        | Some txt ->
          let open Dns_forward in
          begin match Config.of_string txt with
          | Result.Ok config ->
            domain_search := config.Config.search;
            Lwt.return (Some config)
          | Result.Error (`Msg m) ->
            Log.err (fun f -> f "failed to parse %s: %s" (String.concat "/" dns_path) m);
            Lwt.return None
          end
        | None ->
          Lwt.return None
      ) string_dns_settings
    >>= fun dns_settings ->

    let domain_name = ref "local" in
    let get_domain_name () = !domain_name in
    let domain_name_path = driver @ [ "slirp"; "domain" ] in
    Config.string config ~default:(!domain_name) domain_name_path
    >>= fun domain_name_settings ->
    Lwt.async
      (fun () ->
        Active_config.iter
          (fun x ->
            domain_name := x;
            Lwt.return_unit
          ) domain_name_settings
      );

    let bind_path = driver @ [ "allowed-bind-address" ] in
    Config.string_option config bind_path
    >>= fun string_allowed_bind_address ->
    let parse_bind_address = function
      | None -> Lwt.return None
      | Some x ->
        let strings = List.map String.trim @@ Stringext.split x ~on:',' in
        let ip_opts = List.map
            (fun x ->
               try
                 if x = ""
                 then None
                 else Some (Ipaddr.of_string_exn x)
               with _ ->
                 Log.err (fun f -> f "Failed to parse IP address in allowed-bind-address: %s" x);
                 None
            ) strings in
        let ips = List.fold_left (fun acc x -> match x with None -> acc | Some x -> x :: acc) [] ip_opts in
        Lwt.return (Some ips) in
    Active_config.map parse_bind_address string_allowed_bind_address
    >>= fun allowed_bind_address ->

    let rec monitor_allowed_bind_settings allowed_bind_address =
      Forward.set_allowed_addresses (Active_config.hd allowed_bind_address);
      Active_config.tl allowed_bind_address
      >>= fun allowed_bind_address ->
      monitor_allowed_bind_settings allowed_bind_address in
    Lwt.async (fun () -> log_exception_continue "monitor_allowed_bind_settings" (fun () -> monitor_allowed_bind_settings allowed_bind_address));

    let peer_ips_path = driver @ [ "slirp"; "docker" ] in
    let parse_ipv4 default x = match Ipaddr.V4.of_string @@ String.trim x with
      | None ->
        Log.err (fun f -> f "Failed to parse IPv4 address '%s', using default of %s" x (Ipaddr.V4.to_string default));
        Lwt.return default
      | Some x -> Lwt.return x in
    let parse_ipv4_list default x =
      let all = List.map Ipaddr.V4.of_string @@ List.filter (fun x -> x <> "") @@ List.map String.trim @@ Astring.String.cuts ~sep:"," x in
      let any_none, some = List.fold_left (fun (any_none, some) x -> match x with
          | None -> true, some
          | Some x -> any_none, x :: some
        ) (false, []) all in
      if any_none then begin
        Log.err (fun f -> f "Failed to parse IPv4 address list '%s', using default of %s" x (String.concat "," (List.map Ipaddr.V4.to_string default)));
        Lwt.return default
      end else Lwt.return some in

    Config.string config ~default:default_peer peer_ips_path
    >>= fun string_peer_ips ->
    Active_config.map (parse_ipv4 (Ipaddr.V4.of_string_exn default_peer)) string_peer_ips
    >>= fun peer_ips ->
    Lwt.async (fun () -> restart_on_change "slirp/docker" Ipaddr.V4.to_string peer_ips);

    let host_ips_path = driver @ [ "slirp"; "host" ] in
    Config.string config ~default:default_host host_ips_path
    >>= fun string_host_ips ->
    Active_config.map (parse_ipv4 (Ipaddr.V4.of_string_exn default_host)) string_host_ips
    >>= fun host_ips ->
    Lwt.async (fun () -> restart_on_change "slirp/host" Ipaddr.V4.to_string host_ips);

    let extra_dns_ips_path = driver @ [ "slirp"; "extra_dns" ] in
    Config.string config ~default:(String.concat "," default_dns_extra) extra_dns_ips_path
    >>= fun string_extra_dns_ips ->
    Active_config.map (parse_ipv4_list (List.map Ipaddr.V4.of_string_exn default_dns_extra)) string_extra_dns_ips
    >>= fun extra_dns_ips ->
    Lwt.async (fun () -> restart_on_change "slirp/extra_dns" (fun x -> String.concat "," (List.map Ipaddr.V4.to_string x)) extra_dns_ips);

    let peer_ip = Active_config.hd peer_ips in
    let local_ip = Active_config.hd host_ips in
    let extra_dns_ip = Active_config.hd extra_dns_ips in

    let rec monitor_dns_settings settings =
      let local_address = { Dns_forward.Config.Address.ip = Ipaddr.V4 local_ip; port = 0 } in
      begin match Active_config.hd settings with
        | None ->
          Log.info (fun f -> f "remove resolver override");
          Dns_policy.remove ~priority:3;
          !dns >>= fun t ->
          Dns_forwarder.destroy t
          >>= fun () ->
          dns := Dns_forwarder.create ~local_address (Dns_policy.config ());
          Lwt.return_unit
        | Some (config: Dns_forward.Config.t) ->
          let open Dns_forward in
          Log.info (fun f -> f "updating resolvers to %s" (Config.to_string config));
          Dns_policy.add ~priority:3 ~config;
          !dns >>= fun t ->
          Dns_forwarder.destroy t
          >>= fun () ->
          dns := Dns_forwarder.create ~local_address (Dns_policy.config ());
          Lwt.return_unit
      end
      >>= fun () ->
      Active_config.tl settings
      >>= fun settings ->
      monitor_dns_settings settings in
    Lwt.async (fun () -> log_exception_continue "monitor DNS settings" (fun () -> monitor_dns_settings dns_settings));

    let mtu_path = driver @ [ "slirp"; "mtu" ] in
    Config.int config ~default:default_mtu mtu_path
    >>= fun mtus ->
    Lwt.async (fun () -> restart_on_change "slirp/mtu" string_of_int mtus);
    let mtu = Active_config.hd mtus in

    Log.info (fun f -> f "Creating slirp server peer_ip:%s local_ip:%s domain_search:%s mtu:%d"
                 (Ipaddr.V4.to_string peer_ip) (Ipaddr.V4.to_string local_ip)
                 (String.concat " " !domain_search) mtu
             );

    let t = {
      server_macaddr;
      peer_ip;
      local_ip;
      extra_dns_ip;
      get_domain_search;
      get_domain_name;
      mtu;
    } in
    Lwt.return t

  let connect t client l2_switch =
    (match Vnet.register l2_switch with
    | `Ok x -> Lwt.return x
    | `Error _ -> Lwt.fail (Failure "unable to register device on l2 switch")) 
    >>= fun l2_client_id ->
    let client_macaddr = Vnet.mac l2_switch l2_client_id in
    or_failwith_result "vmnet" @@ Vmnet.of_fd ~client_macaddr ~server_macaddr:t.server_macaddr ~mtu:t.mtu client
    >>= fun x ->
    Log.debug (fun f -> f "accepted vmnet connection");

    connect x l2_switch l2_client_id t.server_macaddr t.peer_ip t.local_ip t.extra_dns_ip t.mtu t.get_domain_search t.get_domain_name
end
