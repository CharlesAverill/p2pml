open Unix
open Common

(* Part 1 Step 3 *)
type machine_info = {hostname: string}

let get_machine_info () : machine_info = {hostname= Unix.gethostname ()}

type node =
  { (* Number of nodes in network *) n_nodes: int
  ; (* Unique node id *) uuid: int
  ; (* File store root *) root: path
  ; (* Files in store *) mutable files: path list
  ; (* Handles to connected nodes *) connections: unit option array
  ; (* Machine information *) machine: machine_info }

let construct_node (n_nodes : int) : node =
  let machine = get_machine_info () in
  { n_nodes
  ; uuid= id_of_hostname machine.hostname
  ; root= "./"
  ; files= []
  ; connections= Array.init n_nodes (fun _ -> None)
  ; machine }

let local_search (n : node) (p : path) : path option =
  List.find_opt (( = ) p) n.files
