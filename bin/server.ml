open P2pml
open Common
open Node
open Messages
open Search
open Logging
open Adjacency

(** Handle individual messages received from a client

    Returns false if an unexpected message was received *)
let handle_msg (self : node) (adj : adj_mat ref)
    (peer_fds : (Unix.inet_addr * Unix.file_descr) list) (addr : Unix.inet_addr)
    (client_sock : Unix.file_descr) (keep : bool ref) = function
  | MachineInfo ->
      _log Log_Info "Received MachineInfo request" ;
      let msg = Bytes.of_string (string_of_node self) in
      ignore (Unix.send client_sock msg 0 (Bytes.length msg) []) ;
      true
  | Search (uuid, fn, hops) ->
      _log Log_Info "Received Search request (%d, %s, %d)" uuid fn hops ;
      handle_search_message
        (Search (uuid, fn, hops))
        addr self.files self.machine.hostname self.uuid !adj peer_fds ;
      true
  | SearchResult (uuid, fn, host) ->
      _log Log_Info "Received SearchResult (%d, %s, %s)" uuid fn host ;
      handle_search_message
        (SearchResult (uuid, fn, host))
        addr self.files self.machine.hostname self.uuid !adj peer_fds ;
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
  | UpdateAdj (id, conns) ->
      if id < Array.length !adj then (
        send_message client_sock
          (ErrMsg
             (Printf.sprintf
                "Invalid machine index for joining. Expected id < %d but got %d"
                (Array.length !adj) id ) ) ;
        false
      ) else (
        adj := pad_adj !adj (id + 1) ;
        List.iteri (fun i b -> if b then !adj.(id).(i) <- 1) conns ;
        true
      )
  | DownloadData _ | ErrMsg _ ->
      false

(* Server thread - loop forever and wait for connections from other nodes *)
let rec server (server_sock : Unix.file_descr) (self : node) (adj : adj_mat ref)
    (peer_fds : (Unix.inet_addr * Unix.file_descr) list ref)
    (peer_fds_mutex : Mutex.t) () : unit =
  let client_sock, client_addr = Unix.accept server_sock in
  let addr =
    match client_addr with
    | Unix.ADDR_INET (a, _) ->
        a
    | _ ->
        fatal rc_Error "Unexpected socket address"
  in
  Mutex.lock peer_fds_mutex ;
  if not (List.mem (addr, client_sock) !peer_fds) then
    peer_fds := (addr, client_sock) :: !peer_fds ;
  Mutex.unlock peer_fds_mutex ;
  ignore
    (Thread.create
       (fun () ->
         let keep = ref true in
         while !keep do
           match recv_message client_sock with
           | Some msg, _
             when handle_msg self adj !peer_fds addr client_sock keep msg = true
             ->
               ()
           | _, buf ->
               _log Log_Error "Server received unexpected message: %s"
                 (String.sub (Bytes.to_string buf) 0
                    (min 64 (Bytes.length buf)) ) ;
               keep := false
         done ;
         Unix.close client_sock )
       () ) ;
  server server_sock self adj peer_fds peer_fds_mutex ()
