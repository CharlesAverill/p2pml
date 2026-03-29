open Common
open Messages
open Logging

(* Dijkstra's algorithm: get distance function between i and other nodes *)
let dijkstra (i : int) (adj : int array array) : int -> int =
  let n = Array.length adj in
  let dist = ref (fun _ -> Int.max_int) in
  let queue = ref (Seq.init n (fun i -> i)) in
  dist := update !dist i 0 ;
  while Seq.length !queue <> 0 do
    let u =
      match
        Seq.fold_left
          (fun acc i ->
            match acc with
            | None ->
                Some i
            | Some x ->
                if !dist i < !dist x then
                  Some i
                else
                  Some x )
          None !queue
      with
      | None ->
          fatal rc_Error "Empty queue in dijkstra"
      | Some u ->
          u
    in
    queue := Seq.filter (fun i -> i <> u) !queue ;
    for u = 0 to n - 1 do
      for v = 0 to n - 1 do
        if adj.(u).(v) = 1 then
          let alt = !dist u + 1 in
          if alt < !dist v then dist := update !dist v alt
      done
    done
  done ;
  !dist

let distance i j adj = dijkstra i adj j

let nodes_at_dist i adj dist_val : int list =
  let f = dijkstra i adj in
  List.filter_map
    (fun j ->
      if f j = dist_val then
        Some j
      else
        None )
    (List.init (Array.length adj) (fun j -> j))

let seen_table : (int, Unix.file_descr option) Hashtbl.t = Hashtbl.create 64

let seen_mutex : Mutex.t = Mutex.create ()

(* Record that we have visited uuid *)
let record_seen (uuid : int) (from_fd : Unix.file_descr option) : bool =
  Mutex.lock seen_mutex ;
  let fresh = not (Hashtbl.mem seen_table uuid) in
  if fresh then Hashtbl.add seen_table uuid from_fd ;
  Mutex.unlock seen_mutex ;
  fresh

(* Get socket associated with a request for download *)
let upstream_of (uuid : int) : Unix.file_descr option =
  Mutex.lock seen_mutex ;
  let r = Hashtbl.find_opt seen_table uuid in
  Mutex.unlock seen_mutex ;
  match r with None -> None | Some fd_opt -> fd_opt

(* Remove state for a finished search *)
let forget (uuid : int) : unit =
  Mutex.lock seen_mutex ;
  Hashtbl.remove seen_table uuid ;
  Mutex.unlock seen_mutex

(* Search results table *)
let results_table : (int, (path * string) list ref) Hashtbl.t =
  Hashtbl.create 16

let results_mutex : Mutex.t = Mutex.create ()

let init_results (uuid : int) : unit =
  Mutex.lock results_mutex ;
  Hashtbl.replace results_table uuid (ref []) ;
  Mutex.unlock results_mutex

let add_result (uuid : int) (fn : path) (host : string) : unit =
  Mutex.lock results_mutex ;
  ( match Hashtbl.find_opt results_table uuid with
  | Some lst ->
      lst := (fn, host) :: !lst
  | None ->
      () ) ;
  Mutex.unlock results_mutex

let get_results (uuid : int) : (path * string) list =
  Mutex.lock results_mutex ;
  let r =
    match Hashtbl.find_opt results_table uuid with
    | Some lst ->
        !lst
    | None ->
        []
  in
  Mutex.unlock results_mutex ; r

let cleanup_results (uuid : int) : unit =
  Mutex.lock results_mutex ;
  Hashtbl.remove results_table uuid ;
  Mutex.unlock results_mutex

(* Send search messages to all nodes within hop_count distance *)
let flood_search (uuid : int) (fn : path) (hop_count : int) (own_id : int)
    (adj : int array array) (peer_fds : (Unix.inet_addr * Unix.file_descr) list)
    (skip_fd : Unix.file_descr option) : unit =
  if hop_count <= 0 then
    ()
  else
    List.iter
      (fun (addr, fd) ->
        let peer_id = id_of_dc_utd_ip addr in
        (* Only forward to neighbours that are adjacent in adj *)
        let is_neighbour =
          peer_id >= 1
          && peer_id <= Array.length adj
          && adj.(own_id - 1).(peer_id - 1) = 1
        in
        let is_skip = match skip_fd with Some s -> s = fd | None -> false in
        if is_neighbour && not is_skip then
          send_message fd (Search (uuid, fn, hop_count - 1)) )
      peer_fds

(* Handle incoming search message from the server thread *)
let handle_search_message (msg : message) (from_fd : Unix.file_descr)
    (self_files : path list) (own_hostname : string) (own_id : int)
    (adj : int array array) (peer_fds : (Unix.inet_addr * Unix.file_descr) list)
    : unit =
  match msg with
  | Search (uuid, fn, hop_count) ->
      if record_seen uuid (Some from_fd) then
        (* First time we see this search request *)
        let have_file = List.mem fn self_files in
        if have_file then
          (* Reply directly back up-stream *)
          send_message from_fd (SearchResult (uuid, fn, own_hostname))
        else if hop_count > 0 then
          (* Forward with decremented hop-count *)
          flood_search uuid fn hop_count own_id adj peer_fds (Some from_fd)
      (* else: hop-count exhausted, drop silently *)

      (* Duplicate - drop *)
  | SearchResult (uuid, fn, host) -> (
    match upstream_of uuid with
    | None ->
        (* We are the initiator - store the result *)
        add_result uuid fn host
    | Some upstream_fd ->
        (* Forward the reply back toward the initiator *)
        send_message upstream_fd (SearchResult (uuid, fn, host)) )
  | _ ->
      ()

(* t_{hop_count} *)
let timer_of_hop_count = float

(* Search for file in network *)
let search (fn : path) (own_id : int) (adj : int array array)
    (peer_fds : (Unix.inet_addr * Unix.file_descr) list) : (path * string) list
    =
  let hop_count = ref 1 in
  let result = ref [] in
  while !result = [] && !hop_count <= 16 do
    (* Create unique identifier for this specific search so that other nodes
       don't drop it *)
    let uuid = Random.int 0x3FFFFFFF in
    (* Register as initiator (no upstream fd) *)
    ignore (record_seen uuid None) ;
    init_results uuid ;
    let timeout = timer_of_hop_count !hop_count in
    _log Log_Info "Searching for '%s' with hop-count=%d (timeout=%.0fs)" fn
      !hop_count timeout ;
    let start = Unix.gettimeofday () in
    flood_search uuid fn !hop_count own_id adj peer_fds None ;
    (* Collect replies until timer expires *)
    let deadline = start +. timeout in
    let done_ = ref false in
    while not !done_ do
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0.0 then
        done_ := true
      else
        (* Poll all peer sockets for incoming SearchResult messages *)
        let fds = List.map snd peer_fds in
        let ready, _, _ = Unix.select fds [] [] (min remaining 0.5) in
        List.iter
          (fun fd ->
            let buf = Bytes.create bufsize in
            let n = Unix.recv fd buf 0 bufsize [] in
            if n > 0 then
              match message_of_bytes buf with
              | Some (SearchResult (rid, rfn, rhost)) when rid = uuid ->
                  let elapsed = Unix.gettimeofday () -. start in
                  _log Log_Info "Reply in %.3fs: '%s' @ %s" elapsed rfn rhost ;
                  add_result uuid rfn rhost
              | Some other ->
                  _log Log_Error
                    "Unexpected message during search: ignored (%s)"
                    ( match other with
                    | Search _ ->
                        "Search"
                    | SearchResult _ ->
                        "SearchResult (wrong uuid)"
                    | _ ->
                        "other" )
              | None ->
                  _log Log_Error "Failed to parse message during search" )
          ready
    done ;
    result := get_results uuid ;
    cleanup_results uuid ;
    forget uuid ;
    if !result = [] then (
      _log Log_Info "No replies for '%s' at hop-count=%d; doubling." fn
        !hop_count ;
      hop_count := !hop_count * 2
    )
  done ;
  if !result = [] then
    _log Log_Info "File '%s' not found in network (hop-count exceeded 16)." fn ;
  !result

(* Download file from remote host *)
let download_file (fn : path) (remote_addr : Unix.inet_addr) (local_root : path)
    : path option =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  repeat_try_connect sock (Unix.ADDR_INET (remote_addr, port)) ;
  send_message sock (Download fn) ;
  (* Chunked download for large files *)
  let chunks = Buffer.create 4096 in
  let tmp = Bytes.create bufsize in
  let keep = ref true in
  while !keep do
    let n = Unix.recv sock tmp 0 bufsize [] in
    if n = 0 then
      keep := false
    else
      Buffer.add_subbytes chunks tmp 0 n
  done ;
  Unix.close sock ;
  let raw = Buffer.to_bytes chunks in
  match message_of_bytes raw with
  | Some (DownloadData (_, data)) ->
      let local_path = Filename.concat local_root (Filename.basename fn) in
      let oc = open_out_bin local_path in
      output_bytes oc data ;
      close_out oc ;
      _log Log_Info "Downloaded '%s' -> '%s'" fn local_path ;
      Some local_path
  | Some (ErrMsg e) ->
      _log Log_Error "Remote error while downloading '%s': %s" fn e ;
      None
  | _ ->
      _log Log_Error "Malformed download reply for '%s'" fn ;
      None
