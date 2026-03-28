open P2pml
open Common
open Node
open Messages
open Logging

let rec server (server_sock : Unix.file_descr) (self : node) () : unit =
  let client_sock, _ = Unix.accept server_sock in
  let buf = Bytes.create bufsize in
  ignore (Unix.recv client_sock buf 0 bufsize []) ;
  match message_of_bytes buf with
  | Some MachineInfo ->
      let msg = Bytes.of_string (string_of_node self) in
      ignore (Unix.send client_sock msg 0 (Bytes.length msg) []) ;
      server server_sock self ()
  | _ ->
      fatal rc_Error "Unrecognized message: %s" (String.of_bytes buf)
