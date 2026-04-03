(** Inter-machine message enoding, decoding, and transfer *)

open Common
open Logging

(** Messages sent between machines *)
type message =
  (* Request for receiver machine information *)
  | MachineInfo
  (* Search for file - uuid * filepath * hop_count *)
  | Search of int * path * int
  (* File found - uuid * filepath * hostname_of_owner *)
  | SearchResult of int * path * string
  (* Request to download a file by name *)
  | Download of path
  (* File transfer - filename * raw contents *)
  | DownloadData of path * bytes
  (* Update global adjacency matrix - machine index * connections *)
  | UpdateAdj of int * bool list
  (* Error occurred *)
  | ErrMsg of string

(** Serialize a message into a byte sequence *)
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
    | UpdateAdj (id, conns) ->
        Printf.sprintf "UPDATEADJ:%d:%s" id
          (String.concat ""
             (List.map
                (fun b ->
                  if b then
                    "1"
                  else
                    "0" )
                conns ) )
    | ErrMsg s ->
        Printf.sprintf "ERR:%s" s )

(** Deserialize a byte sequence into a message *)
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
  | s' when String.starts_with ~prefix:"UPDATEADJ:" s' ->
      (* UPDATEADJ:<id>:<conns> *)
      if
        not
          (string_match (regexp "DOWNLOADDATA:\\([0-9]+\\):\\([0-1]+\\)") s' 0)
      then
        None
      else
        let id = int_of_string (matched_group 1 s') in
        let rest = matched_group 2 s' in
        let conns =
          List.of_seq
            (Seq.map
               (fun c ->
                 if c = '1' then
                   true
                 else
                   false )
               (String.to_seq rest) )
        in
        Some (UpdateAdj (id, conns))
  | s' when String.starts_with ~prefix:"ERR:" s' ->
      if not (string_match (regexp "ERR:\\(.*\\)") s' 0) then
        None
      else
        Some (ErrMsg (matched_group 1 s'))
  | _ ->
      None

(** Send a message [msg] to socket [fd] *)
let send_message (fd : Unix.file_descr) (msg : message) : unit =
  _log Log_Debug "Sending message: %s" (String.of_bytes (bytes_of_message msg)) ;
  ignore
    (Unix.send fd (bytes_of_message msg) 0
       (Bytes.length (bytes_of_message msg))
       [] )

(** Receive a message from a socket [fd] via a blocking wait

    Returns a potentially-decoded message and the received byte sequence *)
let recv_message (fd : Unix.file_descr) : message option * bytes =
  let buf = Bytes.create bufsize in
  ignore (Unix.recv fd buf 0 bufsize []) ;
  (message_of_bytes buf, buf)
