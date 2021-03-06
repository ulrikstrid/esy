type source = {tarballPath : Path.t;}

let sourceTarballPath ~cfg source =
  let id =
    Source.show source
    |> Digest.string
    |> Digest.to_hex
  in
  Path.(cfg.Config.cacheTarballsPath // v id |> addExt "tgz")

let fetchSourceIntoPath source path =
  let open RunAsync.Syntax in
  match source with

  | Source.LocalPath { path = srcPath; manifest = _; } ->
    let%bind names = Fs.listDir srcPath in
    let copy name =
      let src = Path.(srcPath / name) in
      let dst = Path.(path / name) in
      Fs.copyPath ~src ~dst
    in
    let%bind () =
      RunAsync.List.waitAll (List.map ~f:copy names)
    in
    return (Ok ())

  | Source.LocalPathLink _ ->
    (* this case is handled separately *)
    return (Ok ())

  | Source.NoSource ->
    return (Ok ())

  | Source.Archive {url; checksum}  ->
    let f tempPath =
      let%bind () = Fs.createDir tempPath in
      let tarballPath = Path.(tempPath / Filename.basename url) in
      match%lwt Curl.download ~output:tarballPath url with
      | Ok () ->
        let%bind () = Checksum.checkFile ~path:tarballPath checksum in
        let%bind () = Tarball.unpack ~stripComponents:1 ~dst:path tarballPath in
        return (Ok ())
      | Error err -> return (Error err)
    in
    Fs.withTempDir f

  | Source.Github github ->
    let f tempPath =
      let%bind () = Fs.createDir tempPath in
      let tarballPath = Path.(tempPath / "package.tgz") in
      let%bind () =
        let url =
          Printf.sprintf
            "https://api.github.com/repos/%s/%s/tarball/%s"
            github.user github.repo github.commit
        in
        Curl.download ~output:tarballPath url
      in
      let%bind () =  Tarball.unpack ~stripComponents:1 ~dst:path tarballPath in
      return (Ok ())
    in
    Fs.withTempDir f

  | Source.Git git ->
    let%bind () = Git.clone ~dst:path ~remote:git.remote () in
    let%bind () = Git.checkout ~ref:git.commit ~repo:path () in
    let%bind () = Fs.rmPath Path.(path / ".git") in
    return (Ok ())

let fetchSourceIntoCache ~cfg source =
  let open RunAsync.Syntax in
  let tarballPath = sourceTarballPath ~cfg source in

  let%bind tarballIsInCache = Fs.exists tarballPath in

  match tarballIsInCache with
  | true ->
    return (Ok tarballPath)
  | false ->
    Fs.withTempDir (fun sourcePath ->
      let%bind fetched =
        RunAsync.contextf (
          let%bind () = Fs.createDir sourcePath in
          fetchSourceIntoPath source sourcePath
        )
        "fetching %a" Source.pp source
      in

      match fetched with
      | Ok () ->
        let%bind () =
          let%bind () = Fs.createDir (Path.parent tarballPath) in
          let tempTarballPath = Path.(tarballPath |> addExt ".tmp") in
          let%bind () = Tarball.create ~filename:tempTarballPath sourcePath in
          let%bind () = Fs.rename ~src:tempTarballPath tarballPath in
          return ()
        in
        return (Ok tarballPath)
      | Error err -> return (Error err)
    )

let fetch ~cfg source =
  let open RunAsync.Syntax in
  match%bind fetchSourceIntoCache ~cfg source with
  | Ok tarballPath -> return (Ok {tarballPath;})
  | Error err -> return (Error err)

let unpack ~cfg:_ ~dst source =
  Tarball.unpack ~dst source.tarballPath

let fetchAndUnpack ~cfg ~dst source =
  let open RunAsync.Syntax in
  match%bind fetch ~cfg source with
  | Ok source -> unpack ~cfg ~dst source
  | Error err -> Lwt.return (Error err)
