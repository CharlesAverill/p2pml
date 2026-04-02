(** Information about individual nodes of the network *)

open Unix
open Common

(* Part 1 Step 3 *)
type machine_info = {hostname: string}

(** Construct machine info for the device this code is running on *)
let get_machine_info () : machine_info = {hostname= Unix.gethostname ()}

(** Serialize a [machine_info] *)
let string_of_machine_info (m : machine_info) : string =
  Printf.sprintf "=Machine Info=\nHostname: %s" m.hostname

(** Complete local node state *)
type node =
  { (* Number of nodes in network *) n_nodes: int
  ; (* Unique node id *) uuid: int
  ; (* File store root *) root: path
  ; (* Files in store *) mutable files: path list
  ; (* Handles to connected nodes *) connections: unit option array
  ; (* Machine information *) machine: machine_info }

(** Serialize a node *)
let string_of_node (n : node) : string =
  Printf.sprintf
    "==Node==\n\
     Network size: %d\n\
     UUID: %d\n\
     Root: %s\n\
     Files: [%s]\n\
     Connections: %s\n\
     %s"
    n.n_nodes n.uuid n.root
    (String.concat ", " n.files)
    ""
    (string_of_machine_info n.machine)

(** Construct state for the machine running this code *)
let construct_node (n_nodes : int) : node =
  let machine = get_machine_info () in
  let uuid = id_of_hostname machine.hostname in
  let root = Printf.sprintf "./stores/%.2d" uuid in
  { n_nodes
  ; uuid
  ; root
  ; files= List.map (Filename.concat root) (Array.to_list (Sys.readdir root))
  ; connections= Array.init n_nodes (fun _ -> None)
  ; machine }

(** Search for a file in the local machine's store *)
let local_search (n : node) (p : path) : path option =
  List.find_opt (( = ) p) n.files
