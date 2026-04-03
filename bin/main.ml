open P2pml
open Common
open Node
open Adjacency
open Messages
open Search
open Logging
open Argparse
open Server

let () =
  Random.self_init () ;
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
  (* Part 1 Step 4 *)
  let self = construct_node (Array.length adj) in
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
  let peer_fds : (Unix.inet_addr * Unix.file_descr) list ref = ref [] in
  let peer_fds_mutex = Mutex.create () in
  (* Start listening server *)
  let server_sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt server_sock Unix.SO_REUSEADDR true ;
  Unix.bind server_sock
    (Unix.ADDR_INET (Unix.inet_addr_of_string "0.0.0.0", port)) ;
  Unix.listen server_sock 64 ;
  let adj = ref adj in
  let _server_thread =
    Thread.create (server server_sock self adj peer_fds peer_fds_mutex) ()
  in
  (* Connect to neighbours concurrently *)
  let outbound_fds = ref [] in
  let threads =
    List.map
      (fun addr ->
        Thread.create
          (fun () ->
            let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
            repeat_try_connect sock (Unix.ADDR_INET (addr, port)) ;
            Mutex.lock peer_fds_mutex ;
            peer_fds := (addr, sock) :: !peer_fds ;
            outbound_fds := (addr, sock) :: !outbound_fds ;
            Mutex.unlock peer_fds_mutex )
          () )
      neighbour_addrs
  in
  List.iter Thread.join threads ;
  print_endline "===Connection Information===" ;
  List.iter
    (fun (_, sock) ->
      send_message sock MachineInfo ;
      let buf = Bytes.create bufsize in
      ignore (Unix.recv sock buf 0 bufsize []) ;
      print_endline (String.of_bytes buf) )
    !outbound_fds ;
  (* Part 2 - interactive search + download loop *)
  while true do
    Printf.printf "\n>> Request file: %!" ;
    let fn = read_line () in
    match local_search self fn with
    | Some _ ->
        _log Log_Info "File '%s' is available locally\n%!" fn
    | None ->
        let search_results = search fn self.uuid !adj !peer_fds in
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
