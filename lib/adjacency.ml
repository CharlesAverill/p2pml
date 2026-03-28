open Logging
open Common

(* Integer sets *)
module IntSet = Set.Make (Int)
open IntSet

(* Parse adjacency matrix from file *)
let read_adj (p : path) : int array array option =
  let arr =
    Array.of_list
      (List.map
         (fun line ->
           Array.of_seq
             (Seq.map
                (fun c -> int_of_string (String.make 1 c))
                (String.to_seq line) ) )
         (* (In_channel.with_open_text p In_channel.input_lines) ) *)
         (String.split_on_char '\n'
            (String.trim (In_channel.with_open_text p In_channel.input_all)) ) )
  in
  if
    Array.for_all (fun subarr -> Array.length subarr = Array.length arr.(0)) arr
  then
    Some arr
  else
    None

(* Check if an adjacency matrix represents a connected network by performing a
  breadth-first search *)
let connected (adj : int array array) : bool =
  if Array.length adj < 1 then
    fatal rc_Error "Invalid adjacency matrix: length must be positive"
  else
    let cur = ref 0 in
    let found = ref (union empty (singleton !cur)) in
    let queue = ref (Queue.of_seq (List.to_seq [!cur])) in
    (* BFS *)
    while not (Queue.is_empty !queue) do
      cur := Queue.pop !queue ;
      for i = 0 to Array.length adj - 1 do
        if adj.(!cur).(i) = 1 && not (exists (( = ) i) !found) then (
          found := union !found (singleton i) ;
          Queue.add i !queue
        )
      done
    done ;
    IntSet.cardinal !found = Array.length adj
