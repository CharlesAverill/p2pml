open P2pml
open Common
open Node
open Adjacency
open Messages
open Search
open Logging
open Argparse
open Server

let print_connection_info outbound_fds =
  print_endline "===Connection Information===" ;
  List.iter
    (fun (_, sock) ->
      send_message sock MachineInfo ;
      let buf = Bytes.create bufsize in
      ignore (Unix.recv sock buf 0 bufsize []) ;
      print_endline (String.of_bytes buf) )
    outbound_fds

let print_help_message () =
  print_endline
    {|
Enter a file to search the network for, or:

  !help - print this message
  !exit - leave the network and terminate
  !connections - show the information of connected machines
  !adj - print the network's current adjacency matrix
|}

let handle_bang s adj server_sock outbound_fds =
  match s with
  | "!help" ->
      print_help_message ()
  | "!exit" ->
      write_shared kill_server_thread true ;
      (* Send blank message to initiate server thread death *)
      let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Unix.connect sock (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) ;
      Unix.close sock
  | "!connections" ->
      print_connection_info outbound_fds
  | "!adj" ->
      print_endline (string_of_adj adj)
  | _ ->
      unreachable ()

let init (args : arguments) server_sock =
  let adj, self =
    match args.join_node with
    | None -> (
      (* Part 1 Step 2 *)
      match read_adj args.adjacency_file with
      | None ->
          fatal rc_Error "Failed to parse adjacency file"
      | Some adj ->
          if connected adj then (
            _log Log_Info "Adjacency matrix represents connected graph" ;
            (* Part 1 Step 4 *)
            let self = construct_node (Array.length adj) in
            (adj, self)
          ) else
            fatal rc_Error
              "Adjacency matrix does not represent a connected graph" )
    | Some hostname ->
        let self = construct_node 0 in
        let join_addr = (Unix.gethostbyname hostname).Unix.h_addr_list.(0) in
        let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
        repeat_try_connect sock (Unix.ADDR_INET (join_addr, port)) ;
        send_message sock (AugmentAdj self.uuid) ;
        let adj =
          match recv_message sock with
          | Some (WelcomeAdj adj), _ ->
              adj
          | _, buf ->
              send_message sock (LeaveNetwork self.uuid) ;
              fatal rc_Error
                "Failed to connect to network, received [%s] instead of \
                 welcome message"
                (String.of_bytes buf)
        in
        (adj, self)
  in
  (* Determine which neighbors we should connect to (1-indexed) *)
  let neighbour_addrs =
    List.map
      (fun id -> Unix.inet_addr_of_string (dc_utd_ip_of_id id))
      (snd
         (Array.fold_left
            (fun (idx, l) conn ->
              ( idx + 1
              , if idx + 1 = self.uuid || conn <> 1 then
                  l
                else
                  (idx + 1) :: l ) )
            (0, [])
            adj.(self.uuid - 1) ) )
  in
  (* Shared live peer-fd list (addr * fd) - server reads this for forwarding *)
  let peer_fds = create_shared [] in
  let adj = ref adj in
  (* Create the outbound_fds ref early for the server thread - it won't be 
     accessed until an exit occurs, well after it is initialized *)
  let outbound_fds = create_shared [] in
  let _server_thread =
    Thread.create (server server_sock self adj peer_fds outbound_fds) ()
  in
  (* Connect to neighbours concurrently *)
  let threads =
    List.map
      (fun addr ->
        Thread.create
          (fun () ->
            let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
            repeat_try_connect sock (Unix.ADDR_INET (addr, port)) ;
            update_shared peer_fds (fun tl -> (addr, sock) :: tl) ;
            update_shared outbound_fds (fun tl -> (addr, sock) :: tl) )
          () )
      neighbour_addrs
  in
  (adj, self, threads, outbound_fds, peer_fds)

let () =
  Random.self_init () ;
  let args = parse_arguments () in
  (* Start server listening *)
  let server_sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt server_sock Unix.SO_REUSEADDR true ;
  Unix.bind server_sock
    (Unix.ADDR_INET (Unix.inet_addr_of_string "0.0.0.0", port)) ;
  Unix.listen server_sock 64 ;
  (* Initialize node *)
  let adj, self, threads, outbound_fds, peer_fds = init args server_sock in
  (* Wait until all initial nodes are connected and print their machine information *)
  List.iter Thread.join threads ;
  print_connection_info (read_shared outbound_fds) ;
  (* Part 2 - interactive search + download loop *)
  while (not (read_shared kill_server_thread)) || read_shared server_alive do
    Printf.printf "\n>> %!" ;
    let fn = read_line () in
    if String.starts_with ~prefix:"!" (String.trim fn) then
      handle_bang (String.trim fn) !adj server_sock (read_shared outbound_fds)
    else if fn <> "" then
      match local_search self fn with
      | Some _ ->
          _log Log_Info "File '%s' is available locally\n%!" fn
      | None ->
          let search_results =
            search fn self.uuid !adj (read_shared peer_fds)
          in
          if search_results = [] then
            _log Log_Error "File '%s' not found in network\n%!" fn
          else (
            (* Part 2 Step 7 *)
            Printf.printf "\nSearch results:\n" ;
            List.iteri
              (fun i (found_fn, node_name) ->
                Printf.printf "  %d) %s @ %s\n" i found_fn node_name )
              search_results ;
            let n_results = List.length search_results in
            let selection = ref (-1) in
            while !selection < 0 || !selection >= n_results do
              Printf.printf "\n>> Select index to download from (0-%d): %!"
                (n_results - 1) ;
              try selection := read_int () with Failure _ -> ()
            done ;
            let chosen_fn, chosen_host = List.nth search_results !selection in
            (* Part 2 Step 8 *)
            _log Log_Debug "Downloading '%s' from %sn%!" chosen_fn chosen_host ;
            let remote_addr =
              (Unix.gethostbyname chosen_host).Unix.h_addr_list.(0)
            in
            match download_file chosen_fn remote_addr self.root with
            | None ->
                _log Log_Error "Download failed.\n%!"
            | Some local_path ->
                self.files <- local_path :: self.files ;
                _log Log_Info "Saved to '%s'. File added to share list.\n%!"
                  local_path
          )
  done
