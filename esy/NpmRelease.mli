(**
 * Produce an npm release for the [sandbox].
 *)
val make :
  ocamlopt:Path.t
  -> esyInstallRelease:Path.t
  -> outputPath:Path.t
  -> concurrency:int
  -> sandbox:Sandbox.t
  -> unit RunAsync.t
