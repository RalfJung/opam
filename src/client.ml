(***********************************************************************)
(*                                                                     *)
(*    Copyright 2012 OCamlPro                                          *)
(*    Copyright 2012 INRIA                                             *)
(*                                                                     *)
(*  All rights reserved.  This file is distributed under the terms of  *)
(*  the GNU Public License version 3.0.                                *)
(*                                                                     *)
(*  TypeRex is distributed in the hope that it will be useful,         *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of     *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the      *)
(*  GNU General Public License for more details.                       *)
(*                                                                     *)
(***********************************************************************)

open Types
open Utils

let log fmt =
  Globals.log "CLIENT" fmt

open Solver

type t = {
  (* ~/.opam/ *)
  global: Path.G.t;

  (* ~/.opam/$oversion/ *)
  compiler: Path.C.t;

  (* ~/.opam/repo/$repo/ *)
  repositories: (repository * Path.R.t) list;

  (* ~/.opam/opam/ files *)
  available: NV.Set.t;

  (* ~/.opam/$oversion/installed contents *)
  installed: NV.Set.t;

  (* ~/.opam/$oversion/reinstall contents *)
  reinstall: NV.Set.t;

  (* ~/.opam/config contents *)
  config: File.Config.t;

  (* ~/.opam/repo/index contents *)
  repo_index: string N.Map.t;
}

let print_state t =
  let string_of_repos r =
    let s (r,p) =
      Printf.sprintf "%s:%s"
        (Repository.to_string r)
        (Dirname.to_string (Path.R.root p)) in
    String.concat ", " (List.map s r) in
  let string_of_nmap m =
    let s (n,r) = Printf.sprintf "%s:%s" (N.to_string n) r in
    let l = N.Map.fold (fun n r l -> s (n,r)::l) m [] in
    String.concat ", " l in
  log "GLOBAL    : %s" (Dirname.to_string (Path.G.root t.global));
  log "COMPILER  : %s" (Dirname.to_string (Path.C.root t.compiler));
  log "REPO      : %s" (string_of_repos t.repositories);
  log "AVAILABLE : %s" (NV.Set.to_string t.available);
  log "INSTALLED : %s" (NV.Set.to_string t.installed);
  log "REINSTALL : %s" (NV.Set.to_string t.reinstall);
  log "REPO_INDEX: %s" (string_of_nmap t.repo_index)

(* Look into the content of ~/.opam/config to build the client
   state *)
let load_state () =
  log "root path is %s" !Globals.root_path;
  let global = Path.G.create () in
  let config = File.Config.read (Path.G.config global) in
  let ocaml_version = File.Config.ocaml_version config in
  let compiler = Path.C.create ocaml_version in
  let repositories = File.Config.repositories config in
  let repositories = List.map (fun r -> r, Path.R.create r) repositories in
  let repo_index = File.Repo_index.safe_read (Path.G.repo_index global) in
  let installed = File.Installed.safe_read (Path.C.installed compiler) in
  let reinstall = File.Reinstall.safe_read (Path.C.reinstall compiler) in
  let available = Path.G.available global in
  let t = {
    global; compiler; repositories;
    available; installed; reinstall;
    repo_index; config
  } in
  print_state t;
  t

let check () =
  if not (Dirname.exists (Dirname.of_string !Globals.root_path)) then
    Globals.error_and_exit
      "Cannot find %s. Have you run 'opam init first ?"
      !Globals.root_path

let find_repository_path t name =
  let _, r = List.find (fun (r,_) -> Repository.name r = name) t.repositories in
  r

let find_repository t name =
  let r, _ = List.find (fun (r,_) -> Repository.name r = name) t.repositories in
  r

let mem_installed_package_by_name t name =
  not (NV.Set.is_empty (NV.Set.filter (fun nv -> NV.name nv = name) t.installed))

let find_installed_package_by_name t name =
  try NV.Set.choose (NV.Set.filter (fun nv -> NV.name nv = name) t.installed)
  with Not_found ->
    Globals.error_and_exit "Package %s is not installed" (N.to_string name)

let find_available_package_by_name t name =
  let s = NV.Set.filter (fun nv -> NV.name nv = name) t.available in
  if NV.Set.is_empty s then
    None
  else
    Some s

let update () =
  log "update";
  let t = load_state () in

  (* first update all the repo *)
  List.iter (fun (r,_) -> Repositories.update r) t.repositories;

  (* then update $opam/repo/index *)
  let repo_index =
    List.fold_left (fun repo_index (r,p) ->
      let available = Path.R.available p in
      log "repo=%s packages=%s" (Repository.name r) (NV.Set.to_string available);
      NV.Set.fold (fun nv repo_index ->
        let name = NV.name nv in
        if not (N.Map.mem name repo_index) then
          N.Map.add name (Repository.name r) repo_index
        else
          repo_index
      ) available repo_index
    ) t.repo_index t.repositories in
  File.Repo_index.write (Path.G.repo_index t.global) repo_index;

  (* update $opam/$oversion/reinstall *)
  let updated = 
    List.rev_map (fun (r,p) ->
      let updated = File.Updated.safe_read (Path.R.updated p) in
      if not (NV.Set.is_empty updated) then
        Globals.msg "New packages available:\n";
      NV.Set.iter (fun nv ->
        Globals.msg " - %s%s\n"
          (NV.to_string nv)
          (if NV.Set.mem nv t.installed then " (*)" else "")
      ) updated;
      updated
    ) t.repositories in  
  Path.G.fold_compiler (fun () compiler ->
    let installed = File.Installed.safe_read (Path.C.installed compiler) in
    let reinstall = File.Reinstall.safe_read (Path.C.reinstall compiler) in
    let reinstall = 
      List.fold_left (fun reinstall updated -> 
        NV.Set.fold (fun nv reinstall ->
          if NV.Set.mem nv installed then
            NV.Set.add nv reinstall
          else
            reinstall
        ) updated reinstall
      ) reinstall updated in
    if not (NV.Set.is_empty reinstall) then
      File.Reinstall.write (Path.C.reinstall compiler) reinstall
  ) () t.global;

  (* finally create symbolic links from $repo dirs to main dir *)
  N.Map.iter (fun n r ->
    let repo_p = find_repository_path t r in
    let available_versions = Path.R.available_versions repo_p n in
    V.Set.iter (fun v ->
      let nv = NV.create n v in
      let opam_dir = Path.G.opam_dir t.global in
      let opam_f = Path.R.opam repo_p nv in
      let descr_dir = Path.G.descr_dir t.global in
      let descr = Path.R.descr repo_p nv in
      Filename.link_in opam_f opam_dir;
      if Filename.exists descr then
        Filename.link_in descr descr_dir
      else
        Globals.msg "WARNING: %s does not exist\n" (Filename.to_string descr)
    ) available_versions
  ) repo_index;
  (* XXX: we could have a special index for compiler descriptions as
  well, but that's become a bit too heavy *)
  List.iter (fun (r,p) ->
    let comps = Path.R.compiler_list p in
    let comp_dir = Path.G.compiler_dir t.global in
    OCaml_V.Set.iter (fun o ->
      let comp_f = Path.R.compiler p o in
      Filename.link_in comp_f comp_dir
    ) comps
  ) t.repositories;
  (* Check all the dependencies exist *)
  let available = Path.G.available t.global in
  let t = load_state () in
  NV.Set.iter (fun nv ->
    let opam = File.OPAM.read (Path.G.opam t.global nv) in
    let name = File.OPAM.name opam in
    let version = File.OPAM.version opam in
    if nv <> NV.create name version then
      Globals.error_and_exit
        "The file %s is not consistent with the package %s (%s)"
        (Filename.to_string (Path.G.opam t.global nv))
        (N.to_string name)
        (V.to_string version);
    let depends = File.OPAM.depends opam in
    let depopts = File.OPAM.depopts opam in
    List.iter (List.iter (fun ((d,_),_) ->
      match find_available_package_by_name t (N.of_string d) with
        | None   ->
            Globals.error_and_exit
              "Package %s depends on the unknown package %s"
              (N.to_string (NV.name nv)) d
        | Some _ -> ()
    )) (depends @ depopts)
  ) available

let install_initial_package () =
  let t = load_state () in
  let name = N.of_string Globals.default_package in
  let version = V.of_string (Alias.to_string (File.Config.ocaml_version t.config)) in
  let nv = NV.create name version in
  (* .opam *)
  let opam = File.OPAM.create nv in
  File.OPAM.write (Path.G.opam t.global nv) opam;
  (* description *)
  let descr = File.Descr.create "Compiler configuration flags" in
  File.Descr.write (Path.G.descr t.global nv) descr;
  (* .config *)
  let vars = List.map
    (fun (s,p) -> Variable.of_string s, S (Dirname.to_string p))
    [
      ("prefix", Path.C.root t.compiler);
      ("lib", Path.C.lib_dir t.compiler);
      ("bin", Path.C.bin t.compiler);
      ("doc", Path.C.doc_dir t.compiler);
    ] in
  let config = File.Dot_config.create vars in
  File.Dot_config.write (Path.C.config t.compiler name) config;
  (* installed *)
  let installed_p = Path.C.installed t.compiler in
  let installed = File.Installed.safe_read installed_p in
  let installed = NV.Set.add nv installed in
  File.Installed.write installed_p installed;
  (* stublibs *)
  let stublibs = Path.C.stublibs t.compiler in
  Dirname.mkdir stublibs

(* Return the contents of a fully qualified variable *)
let contents_of_variable t v =
  let name = Full_variable.package v in
  let var = Full_variable.variable v in
  let installed = mem_installed_package_by_name t name in
  if var = Variable.enable && installed then
    S "enable"
  else if var = Variable.enable && not installed then
    S "disable"
  else if var = Variable.installed then
    B installed
  else if not installed then
    Globals.error_and_exit "Package %s is not installed" (N.to_string name)
  else begin
    let c = File.Dot_config.safe_read (Path.C.config t.compiler name) in
    try match Full_variable.section v with
      | None   -> File.Dot_config.variable c var
      | Some s -> File.Dot_config.Section.variable c s var
    with Not_found ->
      Globals.error_and_exit "%s is not defined" (Full_variable.to_string v)
  end

(* Substitute the file contents *)
let substitute_file t f =
  let f = Filename.of_basename f in
  let src = Filename.add_extension f "in" in
  let contents = File.Subst.read src in
  let newcontents = File.Subst.replace contents (contents_of_variable t) in
  File.Subst.write f newcontents

(* Substitue the string contents *)
let substitute_string t s =
  File.Subst.replace_string s (contents_of_variable t)

(* We assume that we have the right ocaml-version in $opam/config. Then we:
   - create $opam/$alias
   - compiles and install $opam/compiler/$descr.comp if $descr <> current version *)
let init_ocaml alias ocaml_version =
  let alias_p = Path.C.create alias in
  if not (Dirname.exists (Path.C.root alias_p)) then 
    let t = load_state () in
    let aliases_f = Path.G.aliases t.global in
    let aliases = File.Aliases.safe_read aliases_f in

  try
    Dirname.mkdir (Path.C.root alias_p);
    File.Installed.write (Path.C.installed alias_p) File.Installed.empty;

    (* Write the default alias *)
    File.Aliases.write aliases_f ((alias, ocaml_version) :: aliases);

    (* Install the initial package and reload the global state *)
    install_initial_package ();
    let t = load_state () in

    (* Update the configuration files *)
    update ();

    (* Install the compiler if necessary *)
    let comp = File.Comp.safe_read (Path.G.compiler t.global ocaml_version) in
    if OCaml_V.current () <> Some ocaml_version && not (File.Comp.preinstalled comp) then begin
      let comp_src = File.Comp.src comp in
      let build_dir = Path.C.build_ocaml alias_p in
      Run.download comp_src (Dirname.to_string build_dir);
      let patches = File.Comp.patches comp in
      List.iter (fun f -> Run.download f (Dirname.to_string build_dir)) patches;
      Run.in_dir
        (Dirname.to_string build_dir)
        (fun () ->
          let patches = List.map Stdlib_filename.basename patches in
          List.iter Run.patch patches);
      let err =
        if File.Comp.configure comp @ File.Comp.make comp <> [] then
          Dirname.exec build_dir
            [ ( "./configure" :: File.Comp.configure comp )
              @ [ "-prefix";  Dirname.to_string (Path.C.root alias_p) ]
            (*-bindir %s/bin -libdir %s/lib -mandir %s/man*)
            (* NOTE In case it exists 2 '-prefix', in general the script
               ./configure will only consider the last one, others will be
               discarded. *)
            ; ( "make" :: File.Comp.make comp )
            ; [ "make" ; "install" ]
          ]
        else
          let builds =
            List.map (List.map (substitute_string t)) (File.Comp.build comp) in
          Dirname.exec build_dir builds
      in
      if err <> 0 then
        Globals.error_and_exit
          "The compilation of compiler version %s failed"
          (OCaml_V.to_string ocaml_version)
    end else
      let comp = Path.G.compiler t.global ocaml_version in
      if not (Filename.exists comp) then
        File.Comp.write comp (File.Comp.create_preinstalled ocaml_version)
  with e -> 
    begin
      Dirname.rmdir (Path.C.root alias_p);
      File.Aliases.write aliases_f aliases;
      raise e;
    end

let init repo alias ocaml_version cores =
  log "init %s" (Repository.to_string repo);
  let root = Path.G.create () in
  let config_f = Path.G.config root in
  if Filename.exists config_f then
    Globals.error_and_exit "%s already exist" (Filename.to_string config_f)
  else try
    let opam_version = OPAM_V.of_string Globals.opam_version in
    let config = File.Config.create opam_version [repo] alias cores in
    let repo_p = Path.R.create repo in
    (* Create (possibly empty) configuration files *)
    File.Config.write config_f config;
    File.Repo_index.write (Path.G.repo_index root) N.Map.empty;
    File.Repo_config.write (Path.R.config repo_p) repo;
    Repositories.init repo;
    Dirname.mkdir (Path.G.opam_dir root);
    Dirname.mkdir (Path.G.descr_dir root);
    Dirname.mkdir (Path.G.archive_dir root);
    Dirname.mkdir (Path.G.compiler_dir root);
    init_ocaml alias ocaml_version;
  with e ->
    if not !Globals.debug then
      Dirname.rmdir (Path.G.root root);
    raise e

let indent_left s nb =
  let nb = nb - String.length s in
  if nb <= 0 then
    s
  else
    s ^ String.make nb ' '

let indent_right s nb =
  let nb = nb - String.length s in
  if nb <= 0 then
    s
  else
    String.make nb ' ' ^ s

let s_not_installed = "--"

let list () =
  log "list";
  let t = load_state () in
  (* Get all the installed packages *)
  let installed = File.Installed.read (Path.C.installed t.compiler) in
  let map, max_n, max_v =
    NV.Set.fold
      (fun nv (map, max_n, max_v) ->
        let name = NV.name nv in
        let version = NV.version nv in
        if
          N.Map.mem name map (* If the packet has been processed yet *)
          &&
          fst (N.Map.find name map) <> None
            (* If moreover the version processed was the version that is installed.
               NB at the time of writing there is at most only 1 [version]
               installed for a given [name]. *)
        then
          map, max_n, max_v
        else
          let is_installed = NV.Set.mem nv installed in
          let descr_f = File.Descr.safe_read (Path.G.descr t.global nv) in
          let synopsis = File.Descr.synopsis descr_f in
          let map = N.Map.add name ((if is_installed then Some version else None), synopsis) map in
          let max_n = max max_n (String.length (N.to_string name)) in
          let max_v = if is_installed then max max_v (String.length (V.to_string version)) else max_v in
          map, max_n, max_v)
      (Path.G.available t.global)
      (N.Map.empty, min_int, String.length s_not_installed)
  in
  N.Map.iter (fun name (version, description) ->
    let version = match version with
    | None   -> s_not_installed
    | Some v -> V.to_string v in
    Globals.msg "%s  %s  %s\n"
      (indent_left (N.to_string name) max_n)
      (indent_right version max_v)
      description) map

let info package =
  log "info %s" (N.to_string package);
  let t = load_state () in

  let o_v =
    let installed = File.Installed.read (Path.C.installed t.compiler) in
    try Some (V.Set.choose_one (N.Map.find package (NV.to_map installed)))
    with Not_found -> None in

  let v_set =
    let v_set =
      try Path.G.available_versions t.global package
      with Not_found ->
        Globals.error_and_exit "unknown package %s" (N.to_string package) in
    match o_v with
      | None   -> v_set
      | Some v -> V.Set.remove v v_set in

  let installed_version = match o_v with
    | None   -> []
    | Some v -> [ "installed-version", V.to_string v ] in

  let available_versions =
    match List.map V.to_string (V.Set.elements v_set) with
    | []  -> []
    | [v] -> [ "available-version" , v ]
    | l   -> [ "available-versions", String.concat ", " l ] in

  let libraries, syntax = match o_v with
    | None   -> [], []
    | Some v ->
        let opam = File.OPAM.read (Path.G.opam t.global (NV.create package v)) in
        let libraries = match File.OPAM.libraries opam with
          | [] -> []
          | l  -> [ "libraries", String.concat ", " (List.map Section.to_string l) ] in
        let syntax = match File.OPAM.syntax opam with
          | [] -> []
          | l  -> [ "syntax", String.concat ", " (List.map Section.to_string l) ] in
        libraries, syntax in

  List.iter
    (fun (tit, desc) -> Globals.msg "%20s: %s\n" tit desc)
    ( [ "package", N.to_string package ]
     @ installed_version
     @ available_versions
     @ libraries
     @ syntax
     @ let latest = match o_v with
         | Some v -> Some v
         | None   ->
             try Some (V.Set.max_elt v_set)
             with Not_found -> None in
       let descr =
         match latest with
         | None   -> File.Descr.empty
         | Some v ->
             File.Descr.safe_read (Path.G.descr t.global (NV.create package v)) in
       [ "description", File.Descr.full descr ]
    )

let confirm fmt =
  Printf.kprintf (fun msg ->
    Globals.msg "%s [Y/n] " msg;
    if not !Globals.yes then
      match read_line () with
      | "y" | "Y"
      | "" -> true
      | _  -> false
    else
      true
  ) fmt

let proceed_toinstall t nv =
  Globals.msg "Installing %s ...\n" (NV.to_string nv);

  let t = load_state () in
  let name = NV.name nv in
  let opam_f = Path.G.opam t.global nv in
  let opam = File.OPAM.read opam_f in
  let config_f = Path.C.build_config t.compiler nv in
  let config = File.Dot_config.safe_read config_f in
  let install_f = Path.C.build_install t.compiler nv in
  let install = File.Dot_install.safe_read install_f in

  Dirname.chdir (Path.C.build t.compiler nv);

  (* check that libraries and syntax extensions specified in .opam and
     .config are in sync *)
  let check kind config_sections opam_sections =
    List.iter (fun cs ->
      if not (List.mem cs opam_sections) then
        Globals.error_and_exit "The %s %s does not appear in %s"
          kind (Section.to_string cs) (Filename.to_string opam_f)
    ) config_sections;
    List.iter (fun os ->
      if not (List.mem os config_sections) then
        Globals.error_and_exit "The %s %s does not appear in %s"
          kind (Section.to_string os) (Filename.to_string config_f)
    ) opam_sections in
  if not (Filename.exists config_f) &&
    (File.OPAM.libraries opam <> [] || File.OPAM.syntax opam <> []) then
    Globals.error_and_exit
      "%s does not exists but %s defines some libraries and syntax extensions"
      (Filename.to_string config_f)
      (Filename.to_string opam_f);
  check "library"
    (File.Dot_config.Library.available config)
    (File.OPAM.libraries opam);
  check "syntax"
    (File.Dot_config.Syntax.available config)
    (File.OPAM.syntax opam);

  (* check that depends (in .opam) and requires (in .config) fields
     are in almost in sync *)
  (* NOTES: the check is partial as we don't know which clause is valid
     in depends (XXX there is surely a way to get it from the solver) *)
  let local_sections = File.Dot_config.Section.available config in
  let libraries_in_opam =
    List.fold_left (fun accu l ->
      List.fold_left (fun accu ((n,_),_) ->
        let n = N.of_string n in
        let nv = find_installed_package_by_name t n in
        let opam = File.OPAM.read (Path.G.opam t.global nv) in
        let libs = File.OPAM.libraries opam in
        let syntax = File.OPAM.syntax opam in
        List.fold_right Section.Set.add (libs @ syntax) accu
      ) accu l
    ) Section.Set.empty (File.OPAM.depends opam) in
  let libraries_in_config =
    List.fold_left (fun accu s ->
      List.fold_left (fun accu r ->
        Section.Set.add r accu
      ) accu (File.Dot_config.Section.requires config s)
    ) Section.Set.empty local_sections in
  Section.Set.iter (fun s ->
    if not (List.mem s local_sections)
    && not (Section.Set.mem s libraries_in_opam) then
      let config_f = Filename.to_string (Path.C.build_config t.compiler nv) in
      let opam_f = Filename.to_string (Path.G.opam t.global nv) in
      let local_sections = List.map Section.to_string local_sections in
      let opam_sections = List.map Section.to_string (Section.Set.elements libraries_in_opam) in
      Globals.error_and_exit
        "%s appears as a library dependency in %s, but:\n\
             - %s defines the libraries {%s}\n\
             - Packages in %s defines the libraries {%s}"
        (Section.to_string s) config_f
        config_f (String.concat ", " local_sections)
        opam_f (String.concat ", " opam_sections)
  ) libraries_in_config;

  (* .install *)
  File.Dot_install.write (Path.C.install t.compiler name) install;

  (* .config *)
  File.Dot_config.write (Path.C.config t.compiler name) config;

  (* lib *)
  let lib = Path.C.lib t.compiler name in
  List.iter (fun f -> Filename.copy_in f lib) (File.Dot_install.lib install);

  (* bin *)
  List.iter (fun (src, dst) ->
    let dst = Path.C.bin t.compiler // (Basename.to_string dst) in
    Filename.copy src dst
  ) (File.Dot_install.bin install);

  (* misc *)
  List.iter
    (fun (src, dst) ->
      if Filename.exists dst && confirm "Overwriting %s ?" (Filename.to_string dst) then
        Filename.copy src dst
      else begin
        Globals.msg "Installing %s to %s.\n" (Filename.to_string src) (Filename.to_string dst);
        if confirm "Continue ?" then
          Filename.copy src dst
      end
    ) (File.Dot_install.misc install)

let proceed_todelete t nv =
  log "deleting %s" (NV.to_string nv);
  let name = NV.name nv in

  (* Run the remove script *)
  let opam = File.OPAM.read (Path.G.opam t.global nv) in
  let remove = File.OPAM.remove opam in
  let root_remove = 
    let p_build = Path.C.build t.compiler nv in
    if Dirname.exists p_build then
      p_build
    else
      let () = Globals.warning "the folder '%s' does not exist anymore" (Dirname.to_string p_build) in
      Path.G.root t.global in
  (* We try to run the remove scripts in the folder where it was extracted
     If it does not exist, we don't really care. *)
  let err = Dirname.exec ~add_to_path:[Path.C.bin t.compiler] root_remove [remove] in
  if err <> 0 then
    Globals.error_and_exit "Cannot uninstall %s" (NV.to_string nv);

  (* Remove the libraries *)
  Dirname.rmdir (Path.C.lib t.compiler name);

  (* Remove the binaries *)
  let install = File.Dot_install.safe_read (Path.C.install t.compiler name) in
  List.iter (fun (_,dst) ->
    let dst = Path.C.bin t.compiler // (Basename.to_string dst) in
    Filename.remove dst
  ) (File.Dot_install.bin install);

  (* Remove the misc files *)
  List.iter (fun (_,dst) ->
    if Filename.exists dst then begin
      Globals.msg "Removing %s." (Filename.to_string dst);
      if confirm "Continue ?" then
        Filename.remove dst
    end
  ) (File.Dot_install.misc install);

  (* Remove .config and .install *)
  Filename.remove (Path.C.install t.compiler name);
  Filename.remove (Path.C.config t.compiler name)

let get_archive t nv =
  log "get_archive %s" (NV.to_string nv);
  let name = NV.name nv in
  let repo = N.Map.find name t.repo_index in
  let repo_p = find_repository_path t repo in
  let repo = find_repository t repo in
  Repositories.download repo nv;
  let src = Path.R.archive repo_p nv in
  let dst = Path.G.archive t.global nv in
  Filename.link src dst;
  dst

type env = {
  add_to_env : (string * string) list;
  add_to_path: dirname;
  old_env    : (string * string) list;
  new_env    : (string * string) list;
}

let expand_env t env =
  List.map (fun (ident, symbol, string) ->
    let string = substitute_string t string in
    match symbol with
    | "="  -> (ident, string)
    | "+=" -> (ident, try string ^ ":" ^ Sys.getenv ident with _ -> string)
    | "=+" -> (ident, try Sys.getenv ident ^ ":" ^ string with _ -> string)
    | _    -> failwith (Printf.sprintf "expand_env: %s is an unknown symbol" symbol)
  ) env

(* XXX: We should get the ones defined in the dependents packages as well *)
let get_env t =
  let aliases = File.Aliases.read (Path.G.aliases t.global) in
  let ocaml_version = List.assoc (File.Config.ocaml_version t.config) aliases in 
  let comp_f = Path.G.compiler t.global ocaml_version in
  let comp = File.Comp.read comp_f in

  let add_to_path = Path.C.bin t.compiler in
  let new_path = "PATH", "+=", Dirname.to_string add_to_path in
  let add_to_env = File.Comp.env comp in
  let new_env = new_path :: add_to_env in

  let old_path = "PATH", "=", try Sys.getenv "PATH" with _ -> "" in
  let old_env = old_path :: List.map (fun (k,_,_) -> k, "=", try Sys.getenv k with _ -> "") add_to_env in

  let add_to_env = expand_env t add_to_env in
  let old_env = expand_env t old_env in
  let new_env = expand_env t new_env in

  { add_to_env; add_to_path; old_env; new_env }

let print_env env =
  List.iter (fun (k,v) ->
    Globals.msg "%s=%s\n" k v
  ) env.new_env

let proceed_tochange t nv_old nv =
  (* First, uninstall any previous version *)
  (match nv_old with
  | Some nv_old -> proceed_todelete t nv_old
  | None        -> ());

  (* Then, untar the archive *)
  let p_build = Path.C.build t.compiler nv in
  Dirname.rmdir p_build;
  Filename.extract (get_archive t nv) p_build;

  let opam = File.OPAM.read (Path.G.opam t.global nv) in

  (* Substitute the configuration files. We should be in the right
     directory to get the correct absolute path for the substitution
     files (see [substitute_file] and [Filename.of_basename]. *)
  Dirname.chdir (Path.C.build t.compiler nv);
  List.iter (substitute_file t) (File.OPAM.substs opam);

  (* Get the env variables set up in the compiler description file *)
  let env = get_env t in

  (* Generate an environnement file *)
  let env_f = Path.C.build_env t.compiler nv in
  File.Env.write env_f env.new_env;
  let old_env_f = Path.C.build_old_env t.compiler nv in
  File.Env.write old_env_f env.old_env;

  (* Call the build script and copy the output files *)
  let commands = List.map (List.map (substitute_string t))
    (File.OPAM.build opam) in
  let commands_s = List.map (fun cmd -> String.concat " " cmd)  commands in
  Globals.msg "[%s] Build commands:\n  %s\n"
    (NV.to_string nv)
    (String.concat "\n  " commands_s);
  let err =
    Dirname.exec
      ~add_to_env:env.add_to_env
      ~add_to_path:[env.add_to_path]
      p_build
      commands in
  if err = 0 then
    try proceed_toinstall t nv
    with e ->
      proceed_todelete t nv;
      raise e
  else (
    proceed_todelete t nv;
    Globals.error_and_exit
      "Compilation failed with error %d" err
  )

(* We need to clean-up things before recompiling. *)
let proceed_torecompile t nv =
  proceed_tochange t (Some nv) nv

let debpkg_of_nv action t nv =
  let opam = File.OPAM.read (Path.G.opam t.global nv) in
  let installed =
    (action <> `upgrade || not (NV.Set.mem nv t.reinstall))
    && NV.Set.mem nv t.installed in
  File.OPAM.to_package opam installed

let resolve action_k t request =
  let l_pkg = NV.Set.fold (fun nv l -> debpkg_of_nv action_k t nv :: l) t.available [] in

  match 
    Solver.resolve
      (Solver.U l_pkg) 
      request
      (if action_k = `upgrade then t.reinstall else NV.Set.empty) 
  with
  | None     -> Globals.msg "No solution has been found.\n"
  | Some sol ->

(*    Globals.msg "The following solution has been found:\n"; *)
      print_solution sol;
      let continue =
        if Solver.delete_or_update sol then
          confirm "Continue ?"
        else
          true in

      if continue then (

        let installed = ref t.installed in
        let write_installed () =
          File.Installed.write (Path.C.installed t.compiler) !installed in

        (* Delete some packages *)
        (* In case of errors, we try to keep the list of installed packages up-to-date *)
        List.iter
          (fun nv ->
            if NV.Set.mem nv !installed then begin
              proceed_todelete t nv;
              installed := NV.Set.remove nv !installed;
              write_installed ()
            end)
          sol.to_remove;

        (* Install or recompile some packages on the child process *)
        let child n =
          let t = load_state () in
          match action n with
          | To_change (o, nv) -> proceed_tochange t o nv
          | To_recompile nv   -> proceed_torecompile t nv
          | To_delete _       -> assert false in

        let pre _ = () in

        (* Update the installed file in the parent process *)
        let post n = match action n with
        | To_delete _    -> assert false
        | To_recompile _ -> ()
        | To_change (None, nv) ->
            installed := NV.Set.add nv !installed;
            write_installed ()
        | To_change (Some o, nv)   ->
            installed := NV.Set.add nv (NV.Set.remove o !installed);
            write_installed () in

        let error n =
          let f msg nv =
            proceed_todelete t nv;
            Globals.error_and_exit "Command failed while %s %s" msg (NV.to_string nv) in
          match action n with
          | To_change (Some _, nv) -> f "upgrading" nv
          | To_change (None, nv)   -> f "installing" nv
          | To_recompile nv        -> f "recompiling" nv
          | To_delete _            -> assert false in

        let cores = File.Config.cores t.config in
        try PA_graph.Parallel.iter cores sol.to_add ~pre ~child ~post
        with PA_graph.Parallel.Errors n -> List.iter error n
      )

let vpkg_of_nv op nv =
  let name = NV.name nv in
  let constr =
    match op with
    | Some op -> Some (op, V.to_string (NV.version nv))
    | None    -> None in
  (N.to_string name, None), constr

let vpkg_of_nv_eq = vpkg_of_nv (Some "=")
let vpkg_of_nv_ge = vpkg_of_nv (Some ">=")
let vpkg_of_nv_le = vpkg_of_nv (Some "<=")
let vpkg_of_nv_any = vpkg_of_nv None

let unknown_package name =
  Globals.error_and_exit "Unable to locate package %S\n" (N.to_string name)

(* transform a name into:
   - <name, installed version> package
   - <$n,$v> package when name = $n.$v *)
let nv_of_name t name =
  let available = NV.to_map (Path.G.available t.global) in
  if N.Map.mem name available then
    NV.create name (V.Set.max_elt (N.Map.find name available))
  else (
    (* consider 'name' to be 'name.version' *)
    let nv =
      try NV.of_string (N.to_string name)
      with Not_found -> unknown_package name in
    let sname = NV.name nv in
    let sversion = NV.version nv in
    Globals.msg
      "Package %s not found, looking for package %s version %s\n"
      (N.to_string name) (N.to_string sname) (V.to_string sversion);
    if N.Map.mem sname available
      && V.Set.mem sversion (N.Map.find sname available) then
      nv
    else
      unknown_package sname
  )

let install names =
  log "install %s" (N.Set.to_string names);
  let t = load_state () in
  let map_installed = NV.to_map t.installed in

  (* Exit if the package is already installed *)
  if N.Set.exists (fun name -> N.Map.mem name map_installed) names then (
    let name =
      N.Set.choose
        (N.Set.filter (fun name -> N.Map.mem name map_installed) names) in
    Globals.msg
      "Package %s is already installed (current version is %s)\n"
      (N.to_string name)
      (V.to_string (V.Set.choose_one (N.Map.find name map_installed)));
    Globals.exit 1
  );

  let new_packages =
    List.map (fun name -> vpkg_of_nv_eq (nv_of_name t name)) (N.Set.elements names) in
  let map_installed =
    List.map
      (fun (x,y) -> NV.create x (V.Set.choose_one y))
      (N.Map.bindings map_installed) in

  resolve `install t
    { wish_install = new_packages @ List.map vpkg_of_nv_any map_installed
    ; wish_remove  = []
    ; wish_upgrade = [] }

let remove name =
  log "remove %s" (N.to_string name);
  if name = N.of_string Globals.default_package then
    Globals.error_and_exit "Package %s can not be removed" Globals.default_package;
  let t = load_state () in
  let nv = nv_of_name t name in
  let universe = Solver.U (NV.Set.fold (fun nv l -> (debpkg_of_nv `remove t nv) :: l) t.available []) in
  let depends = Solver.filter_forward_dependencies universe (Solver.P [debpkg_of_nv `remove t nv]) in
  let depends =
    List.fold_left (fun set dpkg -> NV.Set.add (NV.of_dpkg dpkg) set) NV.Set.empty depends in

  let wish_install =
    List.fold_left
      (fun accu nv ->
        if NV.Set.mem nv depends then
          accu
        else
          vpkg_of_nv_eq nv :: accu
      ) [] (NV.Set.elements t.installed) in

  resolve `remove t
    { wish_install
    ; wish_remove  = [ (N.to_string name, None), None ]
    ; wish_upgrade = [] }

let upgrade () =
  log "upgrade";
  let t = load_state () in
  let available = NV.to_map t.available in
  let aux nv =
    let name = NV.name nv in
    let versions = N.Map.find name available in
    let nv = NV.create name (V.Set.max_elt versions) in
    vpkg_of_nv_ge nv in
  resolve `upgrade t
    { wish_install = []
    ; wish_remove  = []
    ; wish_upgrade = List.map aux (NV.Set.elements t.installed) };
  Filename.remove (Path.C.reinstall t.compiler)

let upload upload repo =
  log "upload %s" (string_of_upload upload);
  let t = load_state () in
  let opam = File.OPAM.read upload.opam in
  let name = File.OPAM.name opam in
  let version = File.OPAM.version opam in
  let nv = NV.create name version in
  let repo = match repo with
  | None ->
      if N.Map.mem name t.repo_index then
        find_repository t (N.Map.find name t.repo_index)
      else
        Globals.error_and_exit "No repository found to upload %s" (NV.to_string nv)
  | Some repo -> find_repository t repo in
  let repo_p = List.assoc repo t.repositories in
  let upload_opam = Path.R.upload_opam repo_p nv in
  let upload_descr = Path.R.upload_descr repo_p nv in
  let upload_archives = Path.R.upload_archives repo_p nv in
  Filename.copy upload.opam upload_opam;
  Filename.copy upload.descr upload_descr;
  Filename.copy upload.archive upload_archives;
  Repositories.upload repo;
  Filename.remove upload_opam;
  Filename.remove upload_descr;
  Filename.remove upload_archives

(* Return the transitive closure of dependencies *)
let get_transitive_dependencies t names =
  let universe =
    Solver.U (List.map (debpkg_of_nv `config t) (NV.Set.elements t.installed)) in
  (* Compute the transitive closure of dependencies *)
  let pkg_of_name n = debpkg_of_nv `config t (find_installed_package_by_name t n) in
  let request = Solver.P (List.map pkg_of_name names) in
  let depends = Solver.filter_backward_dependencies universe request in
  List.map NV.of_dpkg depends

let config request =
  log "config %s" (string_of_config request);
  let t = load_state () in

  match request with
  (* Display the compiler environment variables *)
  | Env -> print_env (get_env t)

  (* List all the available variables *)
  | List_vars ->
      let configs =
        NV.Set.fold (fun nv l ->
          let file = Path.C.config t.compiler (NV.name nv) in
          (nv, File.Dot_config.safe_read file) :: l
        ) t.installed [] in
      let variables =
        List.fold_left (fun accu (nv, c) ->
          let name = NV.name nv in
          (* add all the global variables *)
          let globals =
            List.fold_left (fun accu v ->
              (Full_variable.create_global name v, File.Dot_config.variable c v) :: accu
            ) accu (File.Dot_config.variables c) in
          (* then add the local variables *)
          List.fold_left
            (fun accu n ->
              let variables = File.Dot_config.Section.variables c n in
              List.fold_left (fun accu v ->
                (Full_variable.create_local name n v,
                 File.Dot_config.Section.variable c n v) :: accu
              ) accu variables
            ) globals (File.Dot_config.Section.available c)
        ) [] configs in
      List.iter (fun (fv, contents) ->
        Globals.msg "%-20s : %s\n"
          (Full_variable.to_string fv)
          (string_of_variable_contents contents)
      ) (List.rev variables)

  | Variable v ->
      let contents = contents_of_variable t v in
      Globals.msg "%s\n" (string_of_variable_contents contents)

  | Subst fs -> List.iter (substitute_file t) fs

  | Includes (is_rec, names) ->
      let deps =
        if is_rec then
          List.map NV.name (get_transitive_dependencies t names)
        else
          names in
      let includes =
        List.fold_left (fun accu n ->
          "-I" :: Dirname.to_string (Path.C.lib t.compiler n) :: accu
        ) [] deps in
      Globals.msg "%s\n" (String.concat " " includes)

  | Compil c ->
      let comp =
        let alias = File.Config.ocaml_version t.config in
        let aliases = File.Aliases.read (Path.G.aliases t.global) in
        let oversion = List.assoc alias aliases in
        File.Comp.safe_read (Path.G.compiler t.global oversion) in
      let names =
        List.filter
          (fun n -> NV.Set.exists (fun nv -> NV.name nv = n) t.installed)
          (File.Comp.packages comp)
        @ List.map Full_section.package c.options in
      (* Compute the transitive closure of package dependencies *)
      let package_deps =
        if c.is_rec then
          List.map NV.name (get_transitive_dependencies t names)
        else
          names in
      (* Map from libraries to package *)
      (* NOTES: we check that the set of packages/libraries given on
         the command line is consistent, ie. there isn't two libraries
         with the same name in the transitive closure of
         depedencies *)
      let library_map =
        List.fold_left (fun accu n ->
          let nv = find_installed_package_by_name t n in
          let opam = File.OPAM.read (Path.G.opam t.global nv) in
          let sections = (File.OPAM.libraries opam) @ (File.OPAM.syntax opam) in
          List.iter (fun s ->
            if Section.Map.mem s accu then
              Globals.error_and_exit "Conflict: the library %s appears in %s and %s"
                (Section.to_string s)
                (N.to_string n)
                (N.to_string (Section.Map.find s accu))
          ) sections;
          List.fold_left (fun accu s -> Section.Map.add s n accu) accu sections
        ) Section.Map.empty package_deps in
      (* Compute the transitive closure of libraries dependencies *)
      let library_deps =
        let graph = Section.G.create () in
        let todo = ref Section.Set.empty in
        let add_todo s =
          if Section.Map.mem s library_map then
            todo := Section.Set.add s !todo
          else
            Globals.error_and_exit "Unbound section %S" (Section.to_string s) in
        let seen = ref Section.Set.empty in
        (* Init the graph with vertices from the command-line *)
        (* NOTES: we check that [todo] is initialized before the [loop] *)
        List.iter (fun s ->
          let name = Full_section.package s in
          let sections = match Full_section.section s with
            | None   ->
                let config = File.Dot_config.safe_read (Path.C.config t.compiler name) in
                File.Dot_config.Section.available config
            | Some s -> [s] in
          List.iter (fun s ->
            Section.G.add_vertex graph s;
            add_todo s;
          ) sections
        ) c.options;
        (* Also add the [requires] field of the compiler description *)
        List.iter (fun s ->
          Section.G.add_vertex graph s;
          add_todo s
        ) (File.Comp.requires comp);
        (* Least fix-point to add edges and missing vertices *)
        let rec loop () =
          if not (Section.Set.is_empty !todo) then
            let s = Section.Set.choose !todo in
            todo := Section.Set.remove s !todo;
            seen := Section.Set.add s !seen;
            let name = Section.Map.find s library_map in
            let config = File.Dot_config.safe_read (Path.C.config t.compiler name) in
            let childs = File.Dot_config.Section.requires config s in
            (* keep only the build reqs which are in the package dependency list
               and the ones we haven't already seen *)
            let childs =
              List.filter (fun s ->
                Section.Map.mem s library_map && not (Section.Set.mem s !seen)
              ) childs in
            List.iter (fun child ->
                Section.G.add_vertex graph child;
                Section.G.add_edge graph child s;
                todo := Section.Set.add child !todo;
            ) childs;
            loop ()
        in
        loop ();
        let nodes = ref [] in
        Section.graph_iter (fun n -> nodes := n :: !nodes) graph;
        !nodes in
      let fn_comp = match c.is_byte, c.is_link with
        | true , true  -> File.Comp.bytelink
        | true , false -> File.Comp.bytecomp
        | false, true  -> File.Comp.asmlink
        | false, false -> File.Comp.asmcomp in
      let fn = match c.is_byte, c.is_link with
        | true , true  -> File.Dot_config.Section.bytelink
        | true , false -> File.Dot_config.Section.bytecomp
        | false, true  -> File.Dot_config.Section.asmlink
        | false, false -> File.Dot_config.Section.asmcomp in
      let strs =
        fn_comp comp ::
        List.fold_left (fun accu s ->
          let name = Section.Map.find s library_map in
          let config = File.Dot_config.read (Path.C.config t.compiler name) in
          fn config s :: accu
        ) [] library_deps in
      let output = String.concat " " (List.flatten strs) in
      log "OUTPUT: %S" output;
      Globals.msg "%s\n" output

let remote action =
  log "remote %s" (string_of_remote action);
  let t = load_state () in
  let repos = File.Config.repositories t.config in
  let update_config repos =
    let new_config = File.Config.with_repositories t.config repos in
    File.Config.write (Path.G.config t.global) new_config in
  let add repo =
    let name = Repository.name repo in
    if List.exists (fun r -> Repository.name r = name) repos then
      Globals.error_and_exit "%s is already a remote repository" name
    else (
      log "Adding %s" (Repository.to_string repo);
      Repositories.init repo;
      Repositories.update repo;
      update_config (repo :: repos)
    ) in
  match action with
  | List  ->
      let pretty_print r =
        Globals.msg "| %-10s| %-40s| %-10s |\n"
          (Repository.name r)
          (Repository.address r)
          (Repository.kind r) in
      let line = String.make 68 '-' in
      line.[0] <- '|'; line.[12] <- '|'; line.[54] <- '|'; line.[67] <- '|';
      Globals.msg "%s\n| %-10s| %-40s| %-10s |\n%s\n"
        line "NAME" "ADDRESS" "KIND" line;
      List.iter pretty_print repos;
      Globals.msg "%s\n" line
  | Add r -> add r
  | Rm n  ->
      let repo =
        try List.find (fun r -> Repository.name r = n) repos
        with Not_found ->
          Globals.error_and_exit "%s is not a remote index" n in
      update_config (List.filter ((!=) repo) repos)

let compiler_list () =
  log "compiler_list";
  let t = load_state () in
  let descrs = Path.G.compiler_list t.global in
  let aliases = File.Aliases.read (Path.G.aliases t.global) in
  Globals.msg "--- Compilers installed ---\n";
  List.iter (fun (n,c) ->
    let current = if n = File.Config.ocaml_version t.config then "*" else " " in
    Globals.msg "%s %s (%s)\n" current (Alias.to_string n) (OCaml_V.to_string c)
  ) aliases;
  Globals.msg "\n--- Compilers available ---\n";
  OCaml_V.Set.iter (fun c ->
    let comp = File.Comp.read (Path.G.compiler t.global c) in
    let preinstalled = if File.Comp.preinstalled comp then "~" else " " in
    Globals.msg "%s  %s\n" preinstalled (OCaml_V.to_string c)
  ) descrs
  
let switch clone alias ocaml_version =
  log "switch %B %s %s" clone
    (Alias.to_string alias)
    (OCaml_V.to_string ocaml_version);
  let t = load_state () in
  let alias_p = Path.C.create alias in

  (* [1/3] write the new version in the configuration file *)
  File.Config.write
    (Path.G.config t.global)
    (File.Config.with_ocaml_version t.config alias);

  (* [2/3] install the new OCaml version *)
  let exists = Dirname.exists (Path.C.root alias_p) in
  if not exists then begin
    try init_ocaml alias ocaml_version;
    with e ->
      (* restore the previous configuration *)
      File.Config.write (Path.G.config t.global) t.config; 
      Dirname.rmdir (Path.C.root alias_p); 
      raise e
  end;

  (* [3/3] install new packagew
     - the packages specified in the compiler descripton file if
       the compiler was not previously installed
     - also attempt to replicate the previous state, if required
       with -clone *)
  let t_new = load_state () in
  let comp_packages =
    if exists then
       t_new.installed
    else
      let comp_f = Path.G.compiler t.global ocaml_version in
      let comp = File.Comp.read comp_f in
      List.fold_left 
        (fun set name -> NV.Set.add (nv_of_name t_new name) set) 
        NV.Set.empty
        (File.Comp.packages comp) in
  let cloned_packages =
    if clone then
      t.installed
    else
      NV.Set.empty in
  let packages = NV.Set.union comp_packages cloned_packages in
  let packages = NV.to_map packages in
  let packages =
    N.Map.fold (fun name versions list ->
      (NV.create name (V.Set.max_elt versions)) :: list
    ) packages [] in
  let wish_install = List.map vpkg_of_nv_eq packages in

  resolve `switch t_new
    { wish_install
    ; wish_remove = [] 
    ; wish_upgrade = [] };

  let env = get_env (load_state ()) in
  print_env env

(** We protect each main functions with a lock depending on its access
on some read/write data. *)

let list () =
  check ();
  list ()

let info package =
  check ();
  info package

let config request =
  check ();
  config request

let install name =
  check ();
  Run.with_flock install name

let update () =
  check ();
  Run.with_flock update ()

let upgrade () =
  check ();
  Run.with_flock upgrade ()

let upload u r =
  check ();
  Run.with_flock upload u r

let remove name =
  check ();
  Run.with_flock remove name

let remote action =
  check ();
  Run.with_flock remote action

let switch oversion =
  check ();
  Run.with_flock switch oversion
