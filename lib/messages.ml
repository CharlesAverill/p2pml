(* Messages sent between machines *)
type message = MachineInfo (* Request for receiver machine information *)

let bytes_of_message (m : message) : bytes =
  String.to_bytes (match m with MachineInfo -> "MACHINE_INFO")

let message_of_bytes (b : bytes) : message option =
  let s =
    match Bytes.index_opt b '\x00' with
    | Some i ->
        Bytes.sub_string b 0 i
    | None ->
        Bytes.to_string b
  in
  match s with "MACHINE_INFO" -> Some MachineInfo | _ -> None
