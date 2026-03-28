open P2pml
open Common
open Node
open Adjacency
open Messages
open Logging
open Argparse
open Server

let () =
  let args = parse_arguments () in
  (* Part 1 Step 2 *)
  let adj =
    match read_adj args.adjacency_file with
    | None ->
        fatal rc_Error "Failed to parse adjacency file"
    | Some adj ->
        if connected adj then (
          _log Log_Info "Adjacency matrix represents connected graph" ;
          adj
        ) else
          fatal rc_Error "Adjacency matrix does not represent a connected graph"
  in
  (* Part 1 Step 4*)
  let self = construct_node (Array.length adj) in
  let to_connect =
    snd
      (Array.fold_left
         (fun (idx, l) conn ->
           ( idx + 1
           , if idx = self.uuid || conn <> 1 then
               (* ignore self-links and non-connections *)
               l
             else
               Unix.inet_addr_of_string (dc_utd_ip_of_id idx) :: l ) )
         (1, []) adj.(self.uuid) )
  in
  (* Socket for receiving machine information requests *)
  let server_sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind server_sock
    (Unix.ADDR_INET (Unix.inet_addr_of_string "0.0.0.0", port)) ;
  Unix.listen server_sock 32 ;
  let server_thread = Thread.create (server server_sock self) () in
  (* Connect to other machines *)
  let connected = ref [] in
  List.iter (fun i -> 
    if not (List.exists (fun (id, _) -> id = i) !connected) then (
      let client_sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      let client_connected = ref false in
      while not !client_connected do
        try
          Unix.connect client_sock (Unix.ADDR_INET (i, port)) ;
          client_connected := true
        with Unix.Unix_error (Unix.ECONNREFUSED, _, _) ->
          (* keep retrying *)
          Thread.delay 1.
      done ;
      connected := (i, client_sock) :: !connected
    )) to_connect ;
  let connected = List.map snd !connected in
  (* Print connection information *)
  print_endline "===Connection Information===" ;
  List.iter
    (fun sock ->
      ignore
        (Unix.send sock
           (bytes_of_message MachineInfo)
           0
           (Bytes.length (bytes_of_message MachineInfo))
           [] ) ;
      let buf = Bytes.create bufsize in
      ignore (Unix.recv sock buf 0 bufsize []) ;
      print_endline (String.of_bytes buf) )
    connected ;
  Thread.join server_thread
