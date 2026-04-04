(** Search for files within the network *)

open Common
open Messages
open Logging
open Adjacency

(** Dijkstra's algorithm

    For a given adjacency matrix [adj], compute a function that determines the
    distance of any node [j] from the given node [i] *)
let dijkstra (i : int) (adj : adj_mat) : int -> int =
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

(** Find the distance between [i] and [j] in the network described by [adj] *)
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

(** Maps search UUID -> address of node we received it from

   None means we are the initiator *)
let seen_table = create_shared (Hashtbl.create 64)

(** Record that we have seen [uuid] coming from [from_addr]

    Returns whether this is the first time [uuid] was seen *)
let record_seen (uuid : int) (from_addr : Unix.inet_addr option) : bool =
  Mutex.lock (snd seen_table) ;
  let tab = !(fst seen_table) in
  let fresh = not (Hashtbl.mem tab uuid) in
  if fresh then Hashtbl.add tab uuid from_addr ;
  Mutex.unlock (snd seen_table) ;
  fresh

(** Get the address to forward a SearchResult back toward the initiator

   Returns [None] if we are the initiator *)
let upstream_of (uuid : int) : Unix.inet_addr option =
  let r = Hashtbl.find_opt (read_shared seen_table) uuid in
  match r with
  | None ->
      (* uuid not in table at all - shouldn't happen *)
      None
  | Some addr_opt ->
      addr_opt

(** Remove state for a completed search *)
let forget (uuid : int) : unit =
  Mutex.lock (snd seen_table) ;
  Hashtbl.remove !(fst seen_table) uuid ;
  Mutex.unlock (snd seen_table)

(** Search results table *)
let results_table = create_shared (Hashtbl.create 16)

(** Initialize search results table with [uuid] as the initializer's ID *)
let init_results (uuid : int) : unit =
  Mutex.lock (snd results_table) ;
  Hashtbl.replace !(fst results_table) uuid (ref []) ;
  Mutex.unlock (snd results_table)

(** Add result [fn] @ [host]([uuid]) to the result table *)
let add_result (uuid : int) (fn : path) (host : string) : unit =
  Mutex.lock (snd results_table) ;
  ( match Hashtbl.find_opt !(fst results_table) uuid with
  | Some lst ->
      lst := (fn, host) :: !lst
  | None ->
      () ) ;
  Mutex.unlock (snd results_table)

(** Get the search results that have returned to the initiator described by [uuid] *)
let get_results (uuid : int) : (path * string) list =
  Mutex.lock (snd results_table) ;
  let r =
    match Hashtbl.find_opt !(fst results_table) uuid with
    | Some lst ->
        !lst
    | None ->
        []
  in
  Mutex.unlock (snd results_table) ;
  r

(** Clear the search results after a completed search *)
let cleanup_results (uuid : int) : unit =
  Mutex.lock (snd results_table) ;
  Hashtbl.remove !(fst results_table) uuid ;
  Mutex.unlock (snd results_table)

(** Open a fresh connection to [addr] and send a message [msg] *)
let send_to_addr (addr : Unix.inet_addr) (msg : message) : unit =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  repeat_try_connect sock (Unix.ADDR_INET (addr, port)) ;
  send_message sock msg ;
  Unix.close sock

(* Part 2 Step 1 *)

(** Send search messages throughout the network [adj] for [fn] within [hop_count]
    distance, skipping [skip_addr] (own address) *)
let flood_search (uuid : int) (fn : path) (hop_count : int) (own_id : int)
    (adj : adj_mat) (peer_fds : (Unix.inet_addr * Unix.file_descr) list)
    (skip_addr : Unix.inet_addr option) : unit =
  if hop_count <= 0 then
    ()
  else
    List.iter
      (fun (addr, _fd) ->
        let peer_id = id_of_dc_utd_ip addr in
        let is_neighbour =
          peer_id >= 1
          && peer_id <= Array.length adj
          && adj.(own_id - 1).(peer_id - 1) = 1
        in
        let is_skip =
          match skip_addr with Some a -> a = addr | None -> false
        in
        if is_neighbour && not is_skip then
          send_to_addr addr (Search (uuid, fn, hop_count - 1)) )
      peer_fds

(** Handle incoming Search or SearchResult [msg] - called from server thread *)
let handle_search_message (msg : message) (from_addr : Unix.inet_addr)
    (self_files : path list) (own_hostname : string) (own_id : int)
    (adj : adj_mat) (peer_fds : (Unix.inet_addr * Unix.file_descr) list) : unit
    =
  match msg with
  | Search (uuid, fn, hop_count) ->
      (* Part 2 Step 2 - suppress duplicates *)
      if record_seen uuid (Some from_addr) then
        let have_file = List.mem fn self_files in
        if have_file then (
          (* Part 2 Step 3 - reply upstream via fresh connection *)
          _log Log_Info "Found '%s', sending SearchResult to %s" fn
            (Unix.string_of_inet_addr from_addr) ;
          send_to_addr from_addr (SearchResult (uuid, fn, own_hostname))
        ) else if hop_count > 0 then
          (* Forward with decremented hop-count, skipping sender *)
          flood_search uuid fn hop_count own_id adj peer_fds (Some from_addr)
      (* else: hop-count exhausted, drop silently *)

      (* Duplicate - drop *)
  | SearchResult (uuid, fn, host) -> (
    match upstream_of uuid with
    | None ->
        (* Part 2 Step 4 - we are the initiator, store the result *)
        _log Log_Info "SearchResult for '%s' reached initiator (from %s)" fn
          host ;
        add_result uuid fn host
    | Some upstream_addr ->
        (* Part 2 Step 5 - forward upstream via fresh connection *)
        _log Log_Info "Forwarding SearchResult for '%s' upstream to %s" fn
          (Unix.string_of_inet_addr upstream_addr) ;
        send_to_addr upstream_addr (SearchResult (uuid, fn, host)) )
  | _ ->
      ()

(** [t_{hop_count}] *)
let timer_of_hop_count = float

(** Search for file [fn] in network [adj] via connections [peer_fds] *)
let search (fn : path) (own_id : int) (adj : adj_mat)
    (peer_fds : (Unix.inet_addr * Unix.file_descr) list) : (path * string) list
    =
  let hop_count = ref 1 in
  let result = ref [] in
  while !result = [] && !hop_count <= 16 do
    let uuid = Random.int 0x3FFFFFFF in
    ignore (record_seen uuid None) ;
    init_results uuid ;
    let timeout = timer_of_hop_count !hop_count in
    _log Log_Info "Searching for '%s' with hop-count=%d (timeout=%.0fs)" fn
      !hop_count timeout ;
    let start = Unix.gettimeofday () in
    flood_search uuid fn !hop_count own_id adj peer_fds None ;
    (* Part 2 Step 6 - wait for server threads to populate results_table *)
    let deadline = start +. timeout in
    while Unix.gettimeofday () < deadline do
      Thread.delay 0.1
    done ;
    result := get_results uuid ;
    cleanup_results uuid ;
    forget uuid ;
    (* Part 2 Step 9 *)
    if !result = [] then (
      _log Log_Info "No replies for '%s' at hop-count=%d; doubling." fn
        !hop_count ;
      hop_count := !hop_count * 2
    )
  done ;
  if !result = [] then
    _log Log_Info "File '%s' not found in network (hop-count exceeded 16)." fn ;
  !result

(** Download file [fn] from remote host @ [remote_addr] to own file store [local_root] *)
let download_file (fn : path) (remote_addr : Unix.inet_addr) (local_root : path)
    : path option =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  repeat_try_connect sock (Unix.ADDR_INET (remote_addr, port)) ;
  send_message sock (Download fn) ;
  (* Chunked read for large files *)
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
