open Notfound

(*** Debugging ***)
let debugging_enabled = Settings.add_bool ("debug", false, `User)

(** print a debug message if debugging is enabled *)
let print message = 
  (if Settings.get_value(debugging_enabled) then prerr_endline message; flush stderr)

(** print a debug message if debugging is enabled; [message] is a lazy expr. *)
let print_l message = 
  (if Settings.get_value(debugging_enabled) then 
     prerr_endline(Lazy.force message); flush stderr)

(** Print a formatted debugging message if debugging is enabled *)
let f fmt = Printf.kprintf print fmt

(** Print a debugging message if debugging is enabled and setting is on.
    [message] is a thunk returning the string to print.
*)
let if_set setting message =
  (if Settings.get_value(setting) then print (message ()))

(* Print [message] if debugging is enabled and setting is on;
   [message] is a lazy expression *)
let if_set_l setting message =
  (if Settings.get_value(setting) then print (Lazy.force message))
