(**

  A subset of yarn.lock format parser which is enough to parse .yarnrc.

 *)
type t =
  | Mapping of (string * t) list
  | Sequence of scalar list
  | Scalar of scalar

and scalar =
  | Number of float
  | String of string
  | Boolean of bool

val parse : string -> (t, string) result
(** Parses a string and returns {!type:t} value or an error. *)

val parseExn : string -> t
(** Same as {!val:parse} but raises {!exception:SyntaxError} *)
