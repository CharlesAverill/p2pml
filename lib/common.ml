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
