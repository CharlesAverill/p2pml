(* Messages sent between machines *)
type message = MachineInfo (* Request for receiver machine information *)

let bytes_of_message (m : message) : bytes =
  String.to_bytes (match m with MachineInfo -> "MACHINE_INFO")

let message_of_bytes (b : bytes) : message option =
  match String.of_bytes b with "MACHINE_INFO" -> Some MachineInfo | _ -> None
