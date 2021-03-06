(**
 * This module describes methods which are performed on build tasks through * "esy-build-package" package builder executable.
 *)

(**
 * Build task.
 *)
val build :
  ?force:bool
  -> ?buildOnly:bool
  -> ?quiet:bool
  -> ?stderrout:[ `Keep | `Log ]
  -> Sandbox.t
  -> Task.t
  -> unit RunAsync.t

(*
 * Spawn an interactive shell inside tbuild environment of the task.
 *)
val buildShell :
  Sandbox.t
  -> Task.t
  -> Unix.process_status RunAsync.t

(*
 * Execute a command inside build environment of the task.
 *)
val buildExec :
  Sandbox.t
  -> Task.t
  -> Cmd.t
  -> Unix.process_status RunAsync.t
