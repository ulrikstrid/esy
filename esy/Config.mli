(** Configuration *)

type t = {
  esyVersion : string;
  prefixPath : Path.t;
  storePath : Path.t;
  fastreplacestringCommand : Cmd.t;
  esyBuildPackageCommand : Cmd.t;
  installCfg : EsyInstall.Config.t;
}

val defaultPrefixPath : Path.t

val make :
  installCfg:EsyInstall.Config.t
  -> fastreplacestringCommand:Cmd.t
  -> esyBuildPackageCommand:Cmd.t
  -> esyVersion:string
  -> prefixPath:Fpath.t option
  -> unit
  -> t Run.t
