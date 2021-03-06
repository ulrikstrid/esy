module Path = EsyLib.Path;

type pattern =
  | Subpath(string)
  | Regex(string);

type config = {allowWrite: list(pattern)};

type err = [ | `Msg(string) | `CommandError(Cmd.t, Bos.OS.Cmd.status)];

type sandbox =
  (~env: Bos.OS.Env.t, Cmd.t) =>
  result(
    (~err: Bos.OS.Cmd.run_err, Bos.OS.Cmd.run_in) => Bos.OS.Cmd.run_out,
    err,
  );

module Darwin = {
  let renderConfig = config => {
    open EsyLib.Sexp;
    let v = x => Value(L(x));
    let renderAllowWrite =
      List.map(
        fun
        | Subpath(p) =>
          v([I("allow"), I("file-write*"), L([I("subpath"), S(p)])])
        | Regex(p) =>
          v([I("allow"), I("file-write*"), L([I("regex"), S(p)])]),
      );
    let doc =
      [
        v([I("version"), N(1.0)]),
        v([I("allow"), I("default")]),
        v([I("deny"), I("file-write*"), L([I("subpath"), S("/")])]),
        v([
          I("allow"),
          I("file-write*"),
          L([I("literal"), S("/dev/null")]),
        ]),
      ]
      @ renderAllowWrite(config.allowWrite);
    render(doc);
  };
  let sandboxExec = config => {
    open Run;
    let configData = renderConfig(config);
    let%bind configFilename = createTmpFile(configData);
    let prepare = (~env, command) => {
      open Bos.OS.Cmd;
      let sandboxCommand =
        Cmd.of_list(["sandbox-exec", "-f", Path.show(configFilename)]);
      let command = Cmd.(sandboxCommand %% command);

      let exec = (~err) => run_io(~env, ~err, command);
      Ok(exec);
    };
    Ok(prepare);
  };
};

let convertEnvToJsonString = env => {
  let json = {
    let f = (k, v, items) => [(k, `String(v)), ...items];
    let items = Astring.String.Map.fold(f, env, []);
    `Assoc(items);
  };
  Yojson.Safe.to_string(json);
};

module Windows = {
  let sandboxExec = _config => {
    let prepare = (~env, command) => {
      open Run;
      open Bos.OS.Cmd;

      /*
       * `esy-bash` takes an optional `--env` parameter with the
       * environment variables that should be used for the bash session.
       *
       * Just passing the env directly to esy-bash doesn't work,
       * because we need the current PATH/env to pick up node and run the shell
       */
      let jsonString = convertEnvToJsonString(env);
      let%bind environmentTempFile = createTmpFile(jsonString);
      let commandAsList = Cmd.to_list(command);

      /* Normalize slashes in the command we send to esy-bash */
      let normalizedCommands =
        Cmd.of_list(
          List.map(EsyLib.Path.normalizePathSlashes, commandAsList),
        );
      let%bind augmentedEsyCommand =
        EsyLib.EsyBash.toEsyBashCommand(
          ~env=Some(Fpath.to_string(environmentTempFile)),
          normalizedCommands,
        );

      let exec = (~err) => run_io(~err, augmentedEsyCommand);
      Ok(exec);
    };
    Ok(prepare);
  };
};

module NoSandbox = {
  let sandboxExec = _config => {
    let prepare = (~env, command) => {
      let exec = (~err) => Bos.OS.Cmd.run_io(~env, ~err, command);
      Ok(exec);
    };
    Ok(prepare);
  };
};

let init = (config: config) =>
  switch (EsyLib.System.Platform.host) {
  | Windows => Windows.sandboxExec(config)
  | Darwin => Darwin.sandboxExec(config)
  | _ => NoSandbox.sandboxExec(config)
  };

let exec = (~env, sandbox: sandbox, cmd) => {
  let result = sandbox(~env, cmd);
  (result: result(_, err) :> Run.t(_, _));
};
