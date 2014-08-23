let ffailwith fmt = Printf.ksprintf failwith fmt

type segment_type =
  | Relocatable
  | Contiguous
  | Absolute of Int32.t

let text_segment_type = ref None
let data_segment_type = ref None
let bss_segment_type = ref None

let section_alignment = ref 7 (* phrase *)

let coff_executable = ref false
let noheaderflag = ref false

let output_name = ref ""

let lib_directories = ref []

let get_path () = List.rev !lib_directories

type file_type =
  | Object_or_archive of string (* filename *)
  | Binary of string (* label *) * string (* filename *)

let files = ref []

let get_files () = List.rev !files

let get_segment_type msg = function
  | "r" | "R" -> Relocatable
  | "x" | "X" -> Contiguous
  | n ->
      let n = Format.sprintf "0x%s" n in
      try Absolute (Int32.of_string n)
      with Failure _ -> ffailwith "Error in %s-segment address: cannot parse %s" msg n

let set_text_segment_type x =
  match x with
  | Relocatable
  | Absolute _ -> text_segment_type := Some x
  | Contiguous -> ffailwith "Error in text-segment address: cannot be contiguous"

let do_file filename =
  let path = get_path() in
  try
    let real_filename = FileExt.find ~path ~ext:[".o"; ".a"] filename in
    Log.message "File %s found: %s" filename real_filename;
    files := Object_or_archive real_filename :: !files
  with Not_found ->
    ffailwith "Cannot find file %s [search path = %s]" filename (String.concat ", " path)

let init_lib_directories () =
  begin try
    let s = Sys.getenv "ALNPATH" in
    lib_directories := StringExt.rev_split ':' s
  with Not_found -> ()
  end;
  begin try
    let s = Sys.getenv "RLNPATH" in
    lib_directories := StringExt.rev_split ':' s @ !lib_directories
  with Not_found -> ()
  end

let info_string =
  let prelude = "Linker by Seb/The Removers (version "^(Version.version)^")" in
  prelude

let mk_spec () =
  let current_incbin = ref None in
  let open Arg in
  ["-a",
   Tuple [String (fun s -> set_text_segment_type (get_segment_type "text" s));
          String (fun s -> data_segment_type := Some (get_segment_type "data" s));
          String (fun s -> bss_segment_type := Some (get_segment_type "bss" s))],
   "<text> <data> <bss> output absolute file (hex value: segment address, r: relocatable segment, x: contiguous segment)";

   "-e", Unit (fun () -> coff_executable := true), "output COF absolute file";

   "-i",
   Tuple [String
            (fun filename ->
              let path = get_path() in
              try
                let real_filename = FileExt.find ~path filename in
                Log.message "Binary file %s found: %s" filename real_filename;
                current_incbin := Some real_filename
              with Not_found ->
                ffailwith "Cannot find binary file %s [path = %s]" filename (String.concat ", " path));
          String
            (fun symbol ->
              match !current_incbin with
              | None -> assert false
              | Some filename ->
                  Log.message "Defining symbol %s for file %s" symbol filename;
                  files := Binary (symbol, filename) :: !files;
                  current_incbin := None)],
   "<fname> <label> incbin <fname> and set <label>";

   "-n", Set noheaderflag, "output no file header to .abs file";
   "-o", String (fun s -> output_name := s), "<name> set output name";

   "-rw", Unit (fun () -> section_alignment := 1), "set alignment size to word size (2 bytes)";
   "-rl", Unit (fun () -> section_alignment := 3), "set alignment size to long size (4 bytes)";
   "-rp", Unit (fun () -> section_alignment := 7), "set alignment size to phrase size (8 bytes)";
   "-rd", Unit (fun () -> section_alignment := 15), "set alignment size to double phrase size (16 bytes)";
   "-rq", Unit (fun () -> section_alignment := 31), "set alignment size to quad phrase size (32 bytes)";

   "-v", Unit (fun () -> Log.set_verbose_mode true), "set verbose mode";
   "-w", Unit (fun () -> Log.set_warning_enabled true), "show linker warnings";
   "-y", String (fun s -> lib_directories := StringExt.rev_split ':' s @ !lib_directories), "<dir1:dir2:...> add directories to search path";
  ]

type 'a obj_kind =
  | Object of 'a
  | Archive of 'a Archive.t

let rec display_obj = function
  | Object {Aout.name; _} ->
      Log.message "OBJ - %s" name
  | Archive {Archive.filename; content} ->
      Log.message "ARCHIVE - %s" filename;
      Array.iter (function {Archive.filename; data; _} -> display_obj (Object data)) content

let load_archive archname content =
  let f ({Archive.filename; data; _} as file) =
    match Aout.load_object filename data with
    | None -> ffailwith "unsupported file in archive %s" archname
    | Some obj -> {file with Archive.data = obj}
  in
  match Archive.load_archive archname content with
  | None -> None
  | Some archive -> Some (Archive.map f archive)

let process_file = function
  | Object_or_archive filename ->
      let content = FileExt.load filename in
      begin match Aout.load_object filename content with
      | None ->
          begin match load_archive filename content with
          | None -> ffailwith "Cannot read file %s (unknown type)" filename
          | Some archive -> Archive archive
          end
      | Some obj -> Object obj
      end
  | Binary (symbol, filename) -> failwith "todo"

let get_summary problem = 
  let process_obj {Aout.symbols; filename; _} = 
    let defined = Hashtbl.create 16 in
    let undefined = Hashtbl.create 16 in
    let add_defined name =
      assert (not (Hashtbl.mem undefined name));
      if Hashtbl.mem defined name then Log.warning "Symbol %s is ambiguous in object %s" name filename
      else Hashtbl.add defined name ()
    in
    let add_undefined name = 
      assert (not (Hashtbl.mem defined name));
      if Hashtbl.mem undefined name then Log.warning "Symbol %s is ambiguous in object %s" name filename
      else Hashtbl.add undefined name ()
    in
    let open Aout in
    let f {name; typ; _} =
      match typ with
      | Type (External, (Text | Data | Bss | Absolute)) -> add_defined name
      | Type (External, Undefined) -> add_undefined name
      | Type (Local, _)
      | Stab _ -> ()
    in
    Array.iter f symbols;
    defined, undefined
  in
  let f = function
    | Object obj -> `Object (process_obj obj)
    | Archive {Archive.content; filename; _} -> 
       let open Archive in
       let n_obj = Array.length content in
       let summary = Array.map (fun {data; _} -> process_obj data) content in
       let defined = Hashtbl.create n_obj in
       let add_defined name no = 
	 if Hashtbl.mem defined name then Log.warning "Symbol %s is multiply defined in archive %s" name filename
	 else Hashtbl.add defined name no
       in
       for i = 0 to n_obj-1 do
	 let def_i, _ = summary.(i) in
	 Hashtbl.iter (fun name () -> add_defined name i) def_i;
       done;
       `Archive (defined, summary)
  in
  Array.map f problem

(*
let defined_by_linker = ["_BSS_E"]

let solve problem =
  let undef_tbl = Hashtbl.create 16 in
  let def_tbl = Hashtbl.create 16 in
  let is_defined sym_name = Hashtbl.mem def_tbl sym_name in
  let mark_defined sym_name =
    if Hashtbl.mem def_tbl sym_name then begin
      Log.warning "Symbol %s is defined several times" sym_name;
      assert (Hashtbl.find def_tbl sym_name)
    end;
    Hashtbl.remove undef_tbl sym_name;
    Hashtbl.replace def_tbl sym_name true
  in
  let mark_unresolved sym_name =
    assert (not (Hashtbl.mem def_tbl sym_name));
    Hashtbl.remove undef_tbl sym_name;
    Hashtbl.replace def_tbl sym_name false
  in
  let mark_undefined sym_name =
    if is_defined sym_name then ()
    else Hashtbl.replace undef_tbl sym_name ()
  in
  List.iter mark_defined defined_by_linker;
  let add_object {global_undefined; global_symbols; _} =
    Hashtbl.iter (fun sym_name _ -> mark_defined sym_name) global_symbols;
    Hashtbl.iter (fun sym_name _ -> mark_undefined sym_name) global_undefined
  in
  let problem =
    let f = function
      | Object obj -> add_object obj; Object (true, obj)
      | Archive archive -> Archive (Archive.map_data (fun obj -> false, obj) archive)
    in
    List.map f problem
  in
  let update_archive sym_name {Archive.content; _} =
    let n = Array.length content in
    let rec aux i =
      if i < n then
        let ({Archive.data = (selected, ({global_symbols; _} as obj))} as file) = content.(i) in
        if not selected && Hashtbl.mem global_symbols sym_name then
          let new_file = {file with Archive.data = (true, obj)} in
          content.(i) <- new_file;
          obj
        else aux (i+1)
      else raise Not_found
    in
    let obj = aux 0 in
    obj
  in
  let rec update_problem sym_name = function
    | [] -> raise Not_found
    | (Object _) :: xs -> update_problem sym_name xs
    | (Archive archive) :: xs ->
        begin try update_archive sym_name archive
        with Not_found -> update_problem sym_name xs
        end
  in
  let rec get_objects = function
    | [] -> []
    | Object (b, obj) :: tl -> if b then obj :: get_objects tl else get_objects tl
    | Archive {Archive.content; filename = archname} :: tl ->
        let objs = get_objects (Array.to_list (Array.map (function {Archive.data; _} -> Object data) content)) in
        let fullname name = archname ^ "/" ^ name in
        let objs = List.map (function ({filename; _} as obj) -> {obj with filename = fullname filename}) objs in
        objs @ get_objects tl
  in
  while Hashtbl.length undef_tbl > 0 do
    let sym_name = hashtbl_choose undef_tbl in
    try add_object (update_problem sym_name problem)
    with Not_found -> mark_unresolved sym_name
  done;
  Hashtbl.iter (fun sym_name b -> if not b then Printf.printf "%s is unresolved\n" sym_name) def_tbl;
  get_objects problem
 *)

let main () =
  try
    init_lib_directories();
    Arg.parse (mk_spec()) do_file info_string;
    let objects = Array.of_list (List.map process_file (get_files())) in
    let summary = get_summary objects in
    ignore summary
    (* List.iter (function {filename; _} -> Printf.printf "Keeping %s\n" filename) solution *)
  with
  | Failure msg -> Log.error msg
  | exn -> Log.error (Printexc.to_string exn)

let _ = main ()
