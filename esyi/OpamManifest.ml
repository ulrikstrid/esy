module Override = Package.OpamOverride

module File = struct
  module Cache = Memoize.Make(struct
    type key = Path.t
    type value = OpamFile.OPAM.t RunAsync.t
  end)

  let ofString ?upgradeIfOpamVersionIsLessThan ?filename data =
    let filename =
      let filename = Option.orDefault ~default:"opam" filename in
      OpamFile.make (OpamFilename.of_string filename)
    in
    let opam = OpamFile.OPAM.read_from_string ~filename data in
    match upgradeIfOpamVersionIsLessThan with
    | Some upgradeIfOpamVersionIsLessThan ->
      let opamVersion = OpamFile.OPAM.opam_version opam in
      if OpamVersion.compare opamVersion upgradeIfOpamVersionIsLessThan < 0
      then OpamFormatUpgrade.opam_file ~filename opam
      else opam
    | None -> opam

  let ofPath ?upgradeIfOpamVersionIsLessThan ?cache path =
    let open RunAsync.Syntax in
    let load () =
      let%bind data = Fs.readFile path in
      let filename = Path.show path in
      return (ofString ?upgradeIfOpamVersionIsLessThan ~filename data)
    in
    match cache with
    | Some cache -> Cache.compute cache path load
    | None -> load ()
end

let readFiles (path : Path.t) () =
  let open RunAsync.Syntax in
  let filesPath = Path.(path / "files") in
  if%bind Fs.isDir filesPath
  then
    let collect files filePath _fileStats =
      match Path.relativize ~root:filesPath filePath with
      | Some name ->
        let%bind file = Package.File.readOfPath ~prefixPath:filesPath ~filePath:name in
        return (file::files)
      | None -> return files
    in
    Fs.fold ~init:[] ~f:collect filesPath
  else return []

type t = {
  name: OpamPackage.Name.t;
  version: OpamPackage.Version.t;
  path : Path.t option;
  opam: OpamFile.OPAM.t;
  url: OpamFile.URL.t option;
  override : Override.t;
  archive : OpamRegistryArchiveIndex.record option;
}

let ofPath ~name ~version (path : Path.t) =
  let open RunAsync.Syntax in
  let%bind opam = File.ofPath path in
  return {
    name;
    version;
    path = Some (Path.parent path);
    opam;
    url = None;
    override = Override.empty;
    archive = None;
  }

let ofString ~name ~version (data : string) =
  let open Run.Syntax in
  let opam = File.ofString data in
  return {
    name;
    version;
    path = None;
    opam;
    url = None;
    override = Override.empty;
    archive = None;
  }

let ocamlOpamVersionToOcamlNpmVersion v =
  let v = OpamPackage.Version.to_string v in
  SemverVersion.Version.parse v

let convertOpamAtom ((name, relop) : OpamFormula.atom) =
  let open Result.Syntax in
  let name =
    match OpamPackage.Name.to_string name with
    | "ocaml" -> "ocaml"
    | name -> "@opam/" ^ name
  in
  match name with
  | "ocaml" ->
    let module C = SemverVersion.Constraint in
    let%bind req =
      match relop with
      | None -> return C.ANY
      | Some (`Eq, v) ->
        begin match OpamPackage.Version.to_string v with
        | "broken" -> error "package is marked as broken"
        | _ ->
          let%bind v = ocamlOpamVersionToOcamlNpmVersion v in
          return (C.EQ v)
        end
      | Some (`Neq, v) ->
        let%bind v = ocamlOpamVersionToOcamlNpmVersion v in return (C.NEQ v)
      | Some (`Lt, v) ->
        let%bind v = ocamlOpamVersionToOcamlNpmVersion v in return (C.LT v)
      | Some (`Gt, v) ->
        let%bind v = ocamlOpamVersionToOcamlNpmVersion v in return (C.GT v)
      | Some (`Leq, v) ->
        let%bind v = ocamlOpamVersionToOcamlNpmVersion v in return (C.LTE v)
      | Some (`Geq, v) ->
        let%bind v = ocamlOpamVersionToOcamlNpmVersion v in return (C.GTE v)
    in
    return {Package.Dep. name; req = Npm req}
  | name ->
    let module C = OpamPackageVersion.Constraint in
    let req =
      match relop with
      | None -> C.ANY
      | Some (`Eq, v) -> C.EQ v
      | Some (`Neq, v) -> C.NEQ v
      | Some (`Lt, v) -> C.LT v
      | Some (`Gt, v) -> C.GT v
      | Some (`Leq, v) -> C.LTE v
      | Some (`Geq, v) -> C.GTE v
    in
    return {Package.Dep. name; req = Opam req}

let convertOpamFormula f =
  let cnf = OpamFormula.to_cnf f in
  Result.List.map ~f:(Result.List.map ~f:convertOpamAtom) cnf

let convertOpamUrl (manifest : t) =
  let open Result.Syntax in

  let sourceOfOpamUrl url =
    let%bind checksum =
      let checksums = OpamFile.URL.checksum url in
      let f c =
        match OpamHash.kind c with
        | `MD5 -> Checksum.Md5, OpamHash.contents c
        | `SHA256 -> Checksum.Sha256, OpamHash.contents c
        | `SHA512 -> Checksum.Sha512, OpamHash.contents c
      in
      match List.map ~f checksums with
      | [] ->
        let msg =
          Format.asprintf
            "no checksum provided for %s@%s"
            (OpamPackage.Name.to_string manifest.name)
            (OpamPackage.Version.to_string manifest.version)
        in
        Error msg
      | checksum::_ -> Ok checksum
    in

    let convert (url : OpamUrl.t) =
      match url.backend with
      | `http ->
        return (Source.Archive {
          url = OpamUrl.to_string url;
          checksum;
        })
      | `rsync -> Error "unsupported source for opam: rsync"
      | `hg -> Error "unsupported source for opam: hg"
      | `darcs -> Error "unsupported source for opam: darcs"
      | `git -> Error "unsupported source for opam: git"
    in

    let%bind main = convert (OpamFile.URL.url url) in
    let mirrors =
      let f mirrors url =
        match convert url with
        | Ok mirror -> mirror::mirrors
        | Error _ -> mirrors
      in
      List.fold_left ~f ~init:[] (OpamFile.URL.mirrors url)
    in
    return (main, mirrors)
  in

  let%bind main, mirrors =
    match manifest.override.Override.opam.Override.Opam.source with
    | Some source ->
      let main = Source.Archive {
        url = source.url;
        checksum = Checksum.Md5, source.checksum;
      } in
      return (main, [])
    | None -> begin
      match manifest.url with
      | Some url -> sourceOfOpamUrl url
      | None ->
        let main = Source.NoSource in
        Ok (main, [])
      end
  in

  match manifest.archive with
  | Some archive ->
    let mirrors = main::mirrors in
    let main =
      Source.Archive {
        url = archive.url;
        checksum = Checksum.Md5, archive.md5;
      }
    in
    Ok (main, mirrors)
  | None ->
    Ok (main, mirrors)

let toOpamFormula reqs =
  let f reqs (req : Req.t) =
    let update =
      match req.spec with
      | VersionSpec.Npm formula ->
        let f (c : SemverVersion.Constraint.t) =
          {Package.Dep. name = req.name; req = Npm c}
        in
        let formula = SemverVersion.Formula.ofDnfToCnf formula in
        List.map ~f:(List.map ~f) formula
      | VersionSpec.NpmDistTag tag ->
        [[{Package.Dep. name = req.name; req = NpmDistTag tag}]]
      | VersionSpec.Opam formula ->
        let f (c : OpamPackageVersion.Constraint.t) =
          {Package.Dep. name = req.name; req = Opam c}
        in
        let formula = OpamPackageVersion.Formula.ofDnfToCnf formula in
        List.map ~f:(List.map ~f) formula
      | VersionSpec.Source spec ->
        [[{Package.Dep. name = req.name; req = Source spec}]]
    in
    reqs @ update
  in
  List.fold_left ~f ~init:[] reqs

let convertDependencies manifest =
  let open Result.Syntax in
  let filterAndConvertOpamFormula ~build ~post ~test ~doc ~dev f =
    let open Result.Syntax in
    let%bind f =
      let f =
        let env var =
          match OpamVariable.Full.to_string var with
          | "test" -> Some (OpamVariable.B test)
          | "doc" -> Some (OpamVariable.B doc)
          | _ -> None
        in
        OpamFilter.partial_filter_formula env f
      in
      try return (OpamFilter.filter_deps ~default:true ~build ~post ~test ~doc ~dev f)
      with Failure msg -> Error msg
    in
    convertOpamFormula f
  in

  let%bind dependencies =
    let%bind formula =
      filterAndConvertOpamFormula
        ~build:true ~post:true ~test:false ~doc:false ~dev:false
        (OpamFile.OPAM.depends manifest.opam)
    in
    let formula =
      formula
      @ [
          [{
            Package.Dep.
            name = "@esy-ocaml/substs";
            req = Npm SemverVersion.Constraint.ANY;
          }];
        ]
      @ toOpamFormula manifest.override.dependencies
      @ toOpamFormula manifest.override.peerDependencies
    in return (Package.Dependencies.OpamFormula formula)
  in

  let%bind devDependencies =
    let%bind formula =
      filterAndConvertOpamFormula
        ~build:false ~post:false ~test:true ~doc:true ~dev:true
        (OpamFile.OPAM.depends manifest.opam)
    in return (Package.Dependencies.OpamFormula formula)
  in

  return (dependencies, devDependencies)

let toPackage ?(ignoreFiles=false) ?source ~name ~version manifest =
  let open RunAsync.Syntax in

  let readOpamFilesForPackage path () =
    let%bind files = readFiles path () in
    return (files @ manifest.override.opam.files)
  in

  let converted =
    let open Result.Syntax in
    let%bind source = convertOpamUrl manifest in
    let%bind dependencies, devDependencies = convertDependencies manifest in
    return (source, dependencies, devDependencies)
  in

  match converted with
  | Error err -> return (Error err)
  | Ok (sourceFromOpam, dependencies, devDependencies) ->

    let source =
      match source with
      | None -> sourceFromOpam
      | Some source -> source, []
    in

    return (Ok {
      Package.
      name;
      version;
      originalVersion = None;
      originalName = None;
      kind = Package.Esy;
      source;
      overrides = Package.Overrides.empty;
      opam = Some {
        Package.Opam.
        name = manifest.name;
        version = manifest.version;
        files = (
          match ignoreFiles, manifest.path with
          | true, _
          | false, None -> (fun () -> return [])
          | false, Some path -> readOpamFilesForPackage path
        );
        opam = manifest.opam;
        override = {manifest.override with opam = Override.Opam.empty};
      };
      dependencies;
      devDependencies;
      resolutions = Package.Resolutions.empty;
    })
