open P2pml
open Common
open Node
open Messages
open Search
open Logging
open Adjacency

(** Denotes if the server thread should be killed, e.g., upon leaving the network *)
let kill_server_thread = create_shared false

(** Denotes if the server thread is done dying *)
let server_alive = create_shared true

(** Handle individual messages received from a client

    Returns false if an unexpected message was received *)
let handle_msg (self : node) (adj : adj_mat ref)
    (peer_fds : (Unix.inet_addr * Unix.file_descr) list shared)
    (addr : Unix.inet_addr) (client_sock : Unix.file_descr) (keep : bool ref) =
  function
  | MachineInfo ->
      _log Log_Info "Received MachineInfo request" ;
      let msg = Bytes.of_string (string_of_node self) in
      ignore (Unix.send client_sock msg 0 (Bytes.length msg) []) ;
      true
  | Search (uuid, fn, hops) when not (read_shared kill_server_thread) ->
      _log Log_Info "Received Search request (%d, %s, %d)" uuid fn hops ;
      handle_search_message
        (Search (uuid, fn, hops))
        addr self.files self.machine.hostname self.uuid !adj
        (read_shared peer_fds) ;
      true
  | Search _ ->
      _log Log_Info "Received Search request while dying" ;
      send_message client_sock
        (ErrMsg (Printf.sprintf "I (%s) am dying" (hostname_of_id self.uuid))) ;
      true
  | SearchResult (uuid, fn, host) ->
      _log Log_Info "Received SearchResult (%d, %s, %s)" uuid fn host ;
      handle_search_message
        (SearchResult (uuid, fn, host))
        addr self.files self.machine.hostname self.uuid !adj
        (read_shared peer_fds) ;
      true
  | Download fn ->
      ( _log Log_Info "Received Download request (%s)" fn ;
        let basename = Filename.basename fn in
        match
          List.find_opt (fun f -> Filename.basename f = basename) self.files
        with
        | None ->
            send_message client_sock
              (ErrMsg (Printf.sprintf "File not found: %s" fn)) ;
            keep := false
        | Some local_path -> (
          try
            let ic = open_in_bin local_path in
            let size = in_channel_length ic in
            let data = Bytes.create size in
            really_input ic data 0 size ;
            close_in ic ;
            send_message client_sock (DownloadData (fn, data)) ;
            keep := false
          with Sys_error e ->
            send_message client_sock (ErrMsg e) ;
            keep := false ) ) ;
      true
  | AugmentAdj (id, conns) ->
      _log Log_Info "Node %d is joining the network" id ;
      if id < Array.length !adj then
        send_message client_sock
          (ErrMsg
             (Printf.sprintf
                "Invalid machine index for joining. Expected id >= %d but got \
                 %d"
                (Array.length !adj) id ) )
      else (
        adj := pad_adj !adj (id + 1) ;
        List.iteri (fun i b -> if b then !adj.(id).(i) <- 1) conns
      ) ;
      true
  | LeaveNetwork id ->
      let id = id - 1 in
      _log Log_Info "Node %d is leaving the network" id ;
      if id >= Array.length !adj then
        send_message client_sock
          (ErrMsg
             (Printf.sprintf
                "Invalid machine index for leaving. Expected id < %d but got %d"
                (Array.length !adj) id ) )
      else (
        (* Clear <id>'s connection row *)
        !adj.(id) <- Array.make (Array.length !adj) 0 ;
        (* Clear <id>'s connection column *)
        for i = 0 to id do
          !adj.(i).(id) <- 0
        done ;
        (* Remove <id>'s entry in peer_fds *)
        write_shared peer_fds
          (List.filter
             (fun (addr, _) -> id_of_dc_utd_ip addr <> id)
             (read_shared peer_fds) )
      ) ;
      true
  | DownloadData _ | ErrMsg _ ->
      false

(** Server thread - loop forever and wait for connections from other nodes *)
let rec server (server_sock : Unix.file_descr) (self : node) (adj : adj_mat ref)
    (peer_fds : (Unix.inet_addr * Unix.file_descr) list shared)
    (outbound_fds : (Unix.inet_addr * Unix.file_descr) list shared) () : unit =
  let client_sock, client_addr = Unix.accept server_sock in
  let addr =
    match client_addr with
    | Unix.ADDR_INET (a, _) ->
        a
    | _ ->
        fatal rc_Error "Unexpected socket address"
  in
  if not (List.mem (addr, client_sock) (read_shared peer_fds)) then
    update_shared peer_fds (fun tl -> (addr, client_sock) :: tl) ;
  ignore
    (Thread.create
       (fun () ->
         let keep = ref true in
         while !keep do
           match recv_message client_sock with
           | Some msg, _
             when handle_msg self adj peer_fds addr client_sock keep msg = true
             ->
               ()
           | _, buf ->
               if Bytes.get buf 0 <> Char.chr 0 then
                 _log Log_Error "Server received unexpected message: %s"
                   (String.sub (Bytes.to_string buf) 0
                      (min 64 (Bytes.length buf)) ) ;
               keep := false
         done ;
         Unix.close client_sock )
       () ) ;
  if read_shared kill_server_thread then (
    _log Log_Critical "Leaving the network upon user request" ;
    List.iter
      (fun (_, peer_fd) -> send_message peer_fd (LeaveNetwork self.uuid))
      (read_shared outbound_fds) ;
    write_shared server_alive false
  ) else
    server server_sock self adj peer_fds outbound_fds ()
