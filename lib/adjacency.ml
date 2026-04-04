(** Handling adjacency matrices *)

open Logging
open Common

(** Integer sets *)
module IntSet = Set.Make (Int)

open IntSet

type adj_mat = int array array

let string_of_adj (adj : adj_mat) : string =
  Array.map
    (fun row -> Array.map string_of_int row |> Array.to_list |> String.concat "")
    adj
  |> Array.to_list |> String.concat "\n"

(** Parse adjacency matrix from a text file located at [p] *)
let read_adj (p : path) : adj_mat option =
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

(** Determine if an adjacency matrix represents a connected network via BFS *)
let connected (adj : adj_mat) : bool =
  if Array.length adj < 1 then
    fatal rc_Error "Invalid adjacency matrix: length must be positive"
  else
    let cur = ref 0 in
    let found = ref (union empty (singleton !cur)) in
    let queue = Queue.of_seq (List.to_seq [!cur]) in
    (* BFS *)
    while not (Queue.is_empty queue) do
      cur := Queue.pop queue ;
      for i = 0 to Array.length adj - 1 do
        if adj.(!cur).(i) = 1 && not (exists (( = ) i) !found) then (
          found := union !found (singleton i) ;
          Queue.add i queue
        )
      done
    done ;
    IntSet.cardinal !found = Array.length adj

(** Pad an n*n adjacency matrix to k*k, where k > n
    
    New rows and columns are zero-initialized *)
let pad_adj (adj : adj_mat) (k : int) : adj_mat =
  if k < Array.length adj then
    adj
  else
    let new_adj : adj_mat = Array.make_matrix k k 0 in
    Array.blit adj 0 new_adj 0 (Array.length adj) ;
    new_adj
