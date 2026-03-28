open Logging
open Str

type path = string

let port = 62631

let bufsize = 1024

let hostname_of_id (id : int) : string =
  if id < 1 || id > 45 then
    fatal rc_Error "Invalid ID"
  else
    Printf.sprintf "dc%.2d.utdallas.edu" id

let id_of_hostname (hostname : string) : int =
  if
    not (string_match (regexp "dc\\([0-9][0-9]\\)\\.utdallas\\.edu") hostname 0)
  then
    fatal rc_Error "Invalid hostname"
  else
    int_of_string (matched_string hostname)
