open P2pml
open Adjacency
open Argparse
open Logging

let () =
  let args = parse_arguments () in
  (* Part 1 Step 2 *)
  match read_adj args.adjacency_file with
  | None ->
      fatal rc_Error "Failed to parse adjacency file"
  | Some adj ->
      print_endline
        ( if connected adj then
            "true"
          else
            "false" )
