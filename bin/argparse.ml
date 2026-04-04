open P2pml.Common
open P2pml.Logging

type arguments = {adjacency_file: path; join_node: string option}

let version = (0, 1)

let version_str =
  "p2pml "
  ^ match version with maj, min -> string_of_int maj ^ "." ^ string_of_int min

let parse_arguments () =
  let adj = ref "" in
  let join_node = ref "" in
  let speclist =
    [ ( "-v"
      , Arg.Unit (fun _ -> print_endline version_str ; exit 0)
      , "Display version information" )
    ; ( "--join"
      , Arg.Set_string join_node
      , "Join an existing network by providing a connected node's address" ) ]
  in
  let usage_msg =
    {|Usage: p2pml [ADJACENCY_FILE|--join <address>]

  --join <address>     Join the network by connecting to an already-connected
                       node, rather than by a given adjacency matrix file

|}
    ^ version_str
  in
  let found_adj = ref false in
  Arg.parse speclist
    (fun n ->
      if !found_adj then
        fatal rc_Error "%s" usage_msg
      else (
        found_adj := true ;
        adj := n
      ) )
    usage_msg ;
  if (not !found_adj) || (!found_adj && !join_node <> "") then
    fatal rc_Error "%s" usage_msg ;
  { adjacency_file= !adj
  ; join_node=
      ( if !join_node = "" then
          None
        else
          Some !join_node ) }
