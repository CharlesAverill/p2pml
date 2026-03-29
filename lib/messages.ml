open Common

(* Messages sent between machines *)
type message =
  | MachineInfo
  (* Request for receiver machine information *)
  | Search of int * path * int
  (* Search for file - uuid * filepath * hop_count *)
  | SearchResult of int * path * string
  (* File found - uuid * filepath * hostname_of_owner *)
  | Download of path
  (* Request to download a file by name *)
  | DownloadData of path * bytes
  (* File transfer - filename * raw contents *)
  | ErrMsg of string

(* Error occurred *)

let bytes_of_message (m : message) : bytes =
  String.to_bytes
    ( match m with
    | MachineInfo ->
        "MACHINE_INFO"
    | Search (id, path, hops) ->
        Printf.sprintf "SEARCH:%d:%d:%s" id hops path
    | SearchResult (id, path, host) ->
        Printf.sprintf "SEARCHRES:%d:%s:%s" id host path
    | Download path ->
        Printf.sprintf "DOWNLOAD:%s" path
    | DownloadData (path, data) ->
        let plen = String.length path in
        Printf.sprintf "DOWNLOADDATA:%d:%s%s" plen path (Bytes.to_string data)
    | ErrMsg s ->
        Printf.sprintf "ERR:%s" s )

let message_of_bytes (b : bytes) : message option =
  let open Str in
  let s =
    match Bytes.index_opt b '\x00' with
    | Some i ->
        Bytes.sub_string b 0 i
    | None ->
        Bytes.to_string b
  in
  match s with
  | "MACHINE_INFO" ->
      Some MachineInfo
  | s' when String.starts_with ~prefix:"SEARCH:" s' ->
      (* SEARCH:<uuid>:<hops>:<path> *)
      if
        not
          (string_match
             (regexp "SEARCH:\\([0-9]+\\):\\([0-9]+\\):\\(.*\\)")
             s' 0 )
      then
        None
      else
        let uuid = int_of_string (matched_group 1 s') in
        let hops = int_of_string (matched_group 2 s') in
        let path = matched_group 3 s' in
        Some (Search (uuid, path, hops))
  | s' when String.starts_with ~prefix:"SEARCHRES:" s' ->
      (* SEARCHRES:<uuid>:<host>:<path> *)
      if
        not
          (string_match
             (regexp "SEARCHRES:\\([0-9]+\\):\\([^:]+\\):\\(.*\\)")
             s' 0 )
      then
        None
      else
        let uuid = int_of_string (matched_group 1 s') in
        let host = matched_group 2 s' in
        let path = matched_group 3 s' in
        Some (SearchResult (uuid, path, host))
  | s' when String.starts_with ~prefix:"DOWNLOAD:" s' ->
      if not (string_match (regexp "DOWNLOAD:\\(.*\\)") s' 0) then
        None
      else
        Some (Download (matched_group 1 s'))
  | s' when String.starts_with ~prefix:"DOWNLOADDATA:" s' ->
      (* DOWNLOADDATA:<path_len>:<path><data> *)
      if not (string_match (regexp "DOWNLOADDATA:\\([0-9]+\\):\\(.*\\)") s' 0)
      then
        None
      else
        let plen = int_of_string (matched_group 1 s') in
        let rest = matched_group 2 s' in
        let path = String.sub rest 0 plen in
        let data =
          Bytes.of_string (String.sub rest plen (String.length rest - plen))
        in
        Some (DownloadData (path, data))
  | s' when String.starts_with ~prefix:"ERR:" s' ->
      if not (string_match (regexp "ERR:\\(.*\\)") s' 0) then
        None
      else
        Some (ErrMsg (matched_group 1 s'))
  | _ ->
      None

let send_message (fd : Unix.file_descr) (msg : message) : unit =
  ignore
    (Unix.send fd (bytes_of_message msg) 0
       (Bytes.length (bytes_of_message msg))
       [] )

let recv_message (fd : Unix.file_descr) : message option * bytes =
  let buf = Bytes.create bufsize in
  ignore (Unix.recv fd buf 0 bufsize []) ;
  (message_of_bytes buf, buf)
