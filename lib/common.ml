open Logging
open Str

type path = string

let port = 62631

let bufsize = 1024

let hostname_of_id (id : int) : string =
  if id < 1 || id > 45 then
    fatal rc_Error "Invalid ID: %d" id
  else
    Printf.sprintf "dc%.2d.utdallas.edu" id

let id_of_hostname (hostname : string) : int =
  if
    not (string_match (regexp "dc\\([0-9][0-9]\\)\\.utdallas\\.edu") hostname 0)
  then
    fatal rc_Error "Invalid hostname: %s" hostname
  else
    int_of_string (matched_group 1 hostname)

let dc_utd_ip_of_id (id : int) : string =
  Printf.sprintf "10.182.157.%d" (4 + id - 1)

let id_of_dc_utd_ip addr =
  let s = Unix.string_of_inet_addr addr in
  try
    let last = int_of_string (List.nth (String.split_on_char '.' s) 3) in
    last - 4 + 1
  with _ -> fatal rc_Error "Failed to parse UTD machine id: %s" s

let update (f : 'a -> 'b) (a : 'a) (b : 'b) : 'a -> 'b =
 fun (a' : 'a) ->
  if a = a' then
    b
  else
    f a'

let repeat_try_connect (fd : Unix.file_descr) (addr : Unix.sockaddr) : unit =
  let client_connected = ref false in
  while not !client_connected do
    try
      Unix.connect fd addr ;
      client_connected := true
    with Unix.Unix_error (Unix.ECONNREFUSED, _, _) -> Thread.delay 1.
  done

let recv_with_timeout (fd : Unix.file_descr) (buf : bytes) (ofs : int)
    (len : int) (timeout : float) =
  let read_fds, _, _ = Unix.select [fd] [] [] timeout in
  if List.mem fd read_fds then
    Some (Unix.recv fd buf ofs len [])
  else
    None

let unreachable () = fatal rc_Error "Unreachable"
