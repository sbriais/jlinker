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

type object_params =
    { filename: string;
      text_size: int;
      data_size: int;
      bss_size: int;
      sym_size: int;
      text_reloc_size: int;
      data_reloc_size: int;
      global_symbols: (string, Int32.t) Hashtbl.t;
      global_undefined: (string, unit) Hashtbl.t;
      content: string; }

type 'a obj_kind =
  | Object of 'a
  | Archive of 'a Archive.t

let rec display_obj = function
  | Object {filename; text_size; data_size; bss_size; sym_size; text_reloc_size; data_reloc_size; _} ->
      Log.message "OBJ - %s, Text %d, Data = %d, BSS = %d, Symbols = %d, Text reloc = %d, Data reloc = %d" filename text_size data_size bss_size sym_size text_reloc_size data_reloc_size
  | Archive {Archive.filename; content} ->
      Log.message "ARCHIVE - %s" filename;
      List.iter (function {Archive.filename; data; _} -> display_obj (Object data)) content

let t_global_mask = 0x01000000l

let load_object filename content =
  let magic = StringExt.read_long content 0 in
  match magic with
  | 0x0000107l
  | 0x0020107l ->
      let text_size = Int32.to_int (StringExt.read_long content 4) in
      let data_size = Int32.to_int (StringExt.read_long content 8) in
      let bss_size = Int32.to_int (StringExt.read_long content 12) in
      let sym_size = Int32.to_int (StringExt.read_long content 16) in
      let text_reloc_size = Int32.to_int (StringExt.read_long content 24) in
      let data_reloc_size = Int32.to_int (StringExt.read_long content 28) in
      let global_symbols = Hashtbl.create 16 in
      let global_undefined = Hashtbl.create 16 in
      let fixup_base = 32 + text_size + data_size + text_reloc_size + data_reloc_size in
      let symbol_base = fixup_base + sym_size in
      let nsymbols = sym_size / 12 in
      for i = 0 to nsymbols - 1 do
        let offset = fixup_base + i * 12 in
        let index = Int32.to_int (StringExt.read_long content offset) in
        let sym_name = StringExt.read_string content (symbol_base + index) '\000' in
        let sym_type = StringExt.read_long content (offset + 4) in
        let sym_value = StringExt.read_long content (offset + 8) in
        let warn sym_name =
          if Hashtbl.mem global_symbols sym_name || Hashtbl.mem global_undefined sym_name then
            Log.warning "Duplicated symbol %s in object file %s" sym_name filename;
        in
        if Int32.logand sym_type t_global_mask = 0l then ()
        else if sym_type = t_global_mask && sym_value = 0l then begin
          warn sym_name;
          Hashtbl.replace global_undefined sym_name ()
        end else begin
          warn sym_name;
          Hashtbl.replace global_symbols sym_name sym_value
        end
      done;
      Some
        { filename;
          text_size;
          data_size;
          bss_size;
          sym_size;
          text_reloc_size;
          data_reloc_size;
          global_symbols;
          global_undefined;
          content }
  | _ -> None

let load_archive archname content =
  let f ({Archive.filename; data; _} as file) =
    match load_object filename data with
    | None -> ffailwith "unsupported file in archive %s" archname
    | Some obj -> {file with Archive.data = obj}
  in
  match Archive.load_archive archname content with
  | None -> None
  | Some archive -> Some (Archive.map f archive)

let rec list_choose f = function
  | [] -> []
  | x :: xs ->
      begin match f x with
      | None -> list_choose f xs
      | Some y -> y :: list_choose f xs
      end

let process_file = function
  | Object_or_archive filename ->
      let content = FileExt.load filename in
      begin match load_object filename content with
      | None ->
          begin match load_archive filename content with
          | None -> ffailwith "Cannot read file %s (unknown type)" filename
          | Some archive -> Archive archive
          end
      | Some obj -> Object obj
      end
  | Binary (symbol, filename) -> failwith "todo"

exception Exit

let hashtbl_choose tbl =
  if Hashtbl.length tbl = 0 then raise Not_found
  else begin
    let result = ref None in
    try Hashtbl.iter (fun x () -> result := Some x; raise Exit) tbl; assert false
    with Exit ->
      match !result with
      | None -> assert false
      | Some x -> x
  end

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
  let update_archive sym_name ({Archive.content; _} as archive) =
    let rec aux = function
      | [] -> raise Not_found
      | ({Archive.data = (selected, ({global_symbols; _} as obj))} as file) :: files ->
          if not selected && Hashtbl.mem global_symbols sym_name then
            let new_file = {file with Archive.data = (true, obj)} in
            obj, new_file :: files
          else
            let obj, files = aux files in
            obj, file :: files
    in
    let obj, new_content = aux content in
    obj, { archive with Archive.content = new_content }
  in
  let rec update_problem sym_name = function
    | [] -> raise Not_found
    | ((Object _) as x) :: xs ->
        let obj, xs = update_problem sym_name xs in
        obj, x :: xs
    | ((Archive archive) as x) :: xs ->
        begin try
          let obj, archive = update_archive sym_name archive in
          obj, (Archive archive) :: xs
        with Not_found ->
          let obj, xs = update_problem sym_name xs in
          obj, x :: xs
        end
  in
  let rec get_objects = function
    | [] -> []
    | Object (b, obj) :: tl -> if b then obj :: get_objects tl else get_objects tl
    | Archive {Archive.content; filename = archname} :: tl ->
        let objs = get_objects (List.map (function {Archive.data; _} -> Object data) content) in
        let fullname name = archname ^ "/" ^ name in
        let objs = List.map (function ({filename; _} as obj) -> {obj with filename = fullname filename}) objs in
        objs @ get_objects tl
  in
  let problem = ref problem in
  while Hashtbl.length undef_tbl > 0 do
    let sym_name = hashtbl_choose undef_tbl in
    begin try
      let obj, new_problem = update_problem sym_name !problem in
      add_object obj;
      problem := new_problem
    with Not_found ->
      mark_unresolved sym_name
    end;
  done;
  Hashtbl.iter (fun sym_name b -> if not b then Printf.printf "%s is unresolved\n" sym_name) def_tbl;
  get_objects !problem

let main () =
  try
    init_lib_directories();
    Arg.parse (mk_spec()) do_file info_string;
    let objects = List.map process_file (get_files()) in
    let solution = solve objects in
    List.iter (function {filename; _} -> Printf.printf "Keeping %s\n" filename) solution
  with
  | Failure msg -> Log.error msg
  | exn -> Log.error (Printexc.to_string exn)

let _ = main ()
