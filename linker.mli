type padding = 
  | Word
  | Long
  | Phrase
  | DoublePhrase
  | QuadPhrase

val link: padding -> Aout.object_params array * (string, int) Hashtbl.t * (string * Int32.t) list -> Aout.object_params