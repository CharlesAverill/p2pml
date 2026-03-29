open P2pml
open Common
open Node
open Messages
open Search
open Logging

(* Server thread - loop forever and wait for connections from other nodes *)
let rec server (server_sock : Unix.file_descr) (self : node)
    (adj : int array array)
    (peer_fds : (Unix.inet_addr * Unix.file_descr) list ref) () : unit =
  let client_sock, _ = Unix.accept server_sock in
  ignore
    (Thread.create
       (fun () ->
         let keep = ref true in
         while !keep do
           match recv_message client_sock with
           | Some MachineInfo, _ ->
              _log Log_Info "Received MachineInfo request";
               let msg = Bytes.of_string (string_of_node self) in
               ignore (Unix.send client_sock msg 0 (Bytes.length msg) [])
           | Some (Search (uuid, fn, hops)), _ ->
              _log Log_Info "Received Searh request (%d, %s, %d)" uuid fn hops;
               handle_search_message
                 (Search (uuid, fn, hops))
                 client_sock self.files self.machine.hostname self.uuid adj
                 !peer_fds
           | Some (SearchResult (uuid, fn, host)), _ ->
              _log Log_Info "Received SearchResult (%d, %s, %s)" uuid fn host;
               handle_search_message
                 (SearchResult (uuid, fn, host))
                 client_sock self.files self.machine.hostname self.uuid adj
                 !peer_fds
           | Some (Download fn), _ -> (
              _log Log_Info "Received Download request (%s)" fn;
               (* Serve file if we have it *)
               let basename = Filename.basename fn in
               match
                 List.find_opt
                   (fun f -> Filename.basename f = basename)
                   self.files
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
                   keep := false ) )
           | _, buf ->
               _log Log_Error "Unrecognized message from client: %s"
                 (String.sub (Bytes.to_string buf) 0
                    (min 64 (Bytes.length buf)) ) ;
               keep := false
         done ;
         Unix.close client_sock )
       () ) ;
  server server_sock self adj peer_fds ()
