module Solution = EsyInstall.Solution
module PackageId = EsyInstall.PackageId
module Package = EsyInstall.Solution.Package
module Installation = EsyInstall.Installation
module Version = EsyInstall.Version

module Task = struct
  type t = {
    id : string;
    pkgId : PackageId.t;
    name : string;
    version : Version.t;
    env : Sandbox.Environment.t;
    buildCommands : Sandbox.Value.t list list;
    installCommands : Sandbox.Value.t list list;
    buildType : Manifest.BuildType.t;
    sourceType : Manifest.SourceType.t;
    sourcePath : Sandbox.Path.t;
    buildScope : Scope.t;
    exportedScope : Scope.t;
    platform : System.Platform.t;
  }

  let plan (t : t) =
    {
      EsyBuildPackage.Plan.
      id = t.id;
      name = t.name;
      version = EsyInstall.Version.show t.version;
      sourceType = t.sourceType;
      buildType = t.buildType;
      build = t.buildCommands;
      install = t.installCommands;
      sourcePath = Sandbox.Path.toValue t.sourcePath;
      env = t.env;
    }

  let to_yojson t = EsyBuildPackage.Plan.to_yojson (plan t)

  let installPath t = Scope.installPath t.exportedScope
  let logPath t = Scope.logPath t.exportedScope

  let renderExpression ~buildConfig task expr =
    let open Run.Syntax in
    let%bind expr = Scope.renderCommandExpr task.exportedScope expr in
    let expr = Sandbox.Value.v expr in
    let expr = Sandbox.Value.render buildConfig expr in
    return expr

  let exposeUserEnv scope =
    scope
    |> Scope.exposeUserEnvWith Sandbox.Environment.Bindings.suffixValue "PATH"
    |> Scope.exposeUserEnvWith Sandbox.Environment.Bindings.suffixValue "MAN_PATH"
    |> Scope.exposeUserEnvWith Sandbox.Environment.Bindings.value "SHELL"

  (* let exposeDevDependenciesEnv task scope = *)
  (*   let f scope dep = *)
  (*     match dep with *)
  (*     | DevDependency, task -> Scope.add ~direct:true ~dep:task.exportedScope scope *)
  (*     | _ -> scope *)
  (*   in *)
  (*   List.fold_left ~f ~init:scope task.dependencies *)

  let buildEnv task = Scope.env ~includeBuildEnv:true task.buildScope

  let commandEnv task =
    task.buildScope
    |> exposeUserEnv
    (* |> exposeDevDependenciesEnv task *)
    |> Scope.env ~includeBuildEnv:true

  let execEnv task =
    task.exportedScope
    |> exposeUserEnv
    (* |> exposeDevDependenciesEnv task *)
    |> Scope.add ~direct:true ~dep:task.exportedScope
    |> Scope.env ~includeBuildEnv:false
end

type t = {
  tasks : Task.t option PackageId.Map.t;
  solution : Solution.t;
}

let renderEsyCommands ~env scope commands =
  let open Run.Syntax in
  let envScope name =
    match Sandbox.Environment.find name env with
    | Some v -> Some (Sandbox.Value.show v)
    | None -> None
  in

  let renderArg v =
    let%bind v = Scope.renderCommandExpr scope v in
    Run.ofStringError (EsyShellExpansion.render ~scope:envScope v)
  in

  let renderCommand =
    function
    | Manifest.Command.Parsed args ->
      let f arg =
        let%bind arg = renderArg arg in
        return (Sandbox.Value.v arg)
      in
      Result.List.map ~f args
    | Manifest.Command.Unparsed line ->
      let%bind line = renderArg line in
      let%bind args = ShellSplit.split line in
      return (List.map ~f:Sandbox.Value.v args)
  in

  match Result.List.map ~f:renderCommand commands with
  | Ok commands -> Ok commands
  | Error err -> Error err

let renderOpamCommands opamEnv commands =
  let open Run.Syntax in
  try
    let commands = OpamFilter.commands opamEnv commands in
    let commands = List.map ~f:(List.map ~f:Sandbox.Value.v) commands in
    return commands
  with
    | Failure msg -> error msg

let renderOpamSubstsAsCommands _opamEnv substs =
  let open Run.Syntax in
  let commands =
    let f path =
      let path = Path.addExt ".in" path in
      [Sandbox.Value.v "substs"; Sandbox.Value.v (Path.show path)]
    in
    List.map ~f substs
  in
  return commands

let renderOpamPatchesToCommands opamEnv patches =
  let open Run.Syntax in
  Run.context (
    let evalFilter = function
      | path, None -> return (path, true)
      | path, Some filter ->
        let%bind filter =
          try return (OpamFilter.eval_to_bool opamEnv filter)
          with Failure msg -> error msg
        in return (path, filter)
    in

    let%bind filtered = Result.List.map ~f:evalFilter patches in

    let toCommand (path, _) =
      let cmd = ["patch"; "--strip"; "1"; "--input"; Path.show path] in
      List.map ~f:Sandbox.Value.v cmd
    in

    return (
      filtered
      |> List.filter ~f:(fun (_, v) -> v)
      |> List.map ~f:toCommand
    )
  ) "processing patch field"

let readManifests (installation : Installation.t) =
  let open RunAsync.Syntax in

  Logs_lwt.debug (fun m -> m "reading manifests");%lwt

  let readManifest (id, loc) =
    let manifest =
      match loc with
      | Installation.Install { path; source = _; } ->
        Manifest.ofDir path
      | Installation.Link { path; manifest } ->
        Manifest.ofDir ?manifest path
    in
    let%bind manifest =
      RunAsync.contextf
        manifest
        "reading manifest %a" PackageId.pp id
    in
    return (id, manifest)
  in

  let%bind items =
    Installation.entries installation
    |> List.map ~f:readManifest
    |> RunAsync.List.joinAll
  in

  let paths, manifests =
    let f (paths, manifests) (id, manifest) =
      match manifest with
      | None ->  paths, manifests
      | Some (manifest, manifestPaths) ->
        let paths = Path.Set.union paths manifestPaths in
        let manifests = PackageId.Map.add id manifest manifests in
        paths, manifests
    in
    List.fold_left ~f ~init:(Path.Set.empty, PackageId.Map.empty) items
  in

  Logs_lwt.debug (fun m -> m "reading manifests: done");%lwt

  return (paths, manifests)

let buildId sandboxEnv build source dependencies =

  let hash =

    (* include ids of dependencies *)
    let dependencies =
      (* let f (direct, dependency) = *)
      (*   match direct, dependency with *)
      (*   | true, (Dependency, task) -> Some ("dep-" ^ task.id) *)
      (*   | true, (BuildTimeDependency, task) -> Some ("buildDep-" ^ task.id) *)
      (*   | true, (DevDependency, _) -> None *)
      (*   | false, _ -> None *)
      (* in *)
      let f dep =
        match dep with
        | _, None -> None
        | false, Some _ -> None
        | true, Some dep -> Some ("dep:" ^ dep.Task.id)
      in
      dependencies
      |> List.map ~f
      |> List.filterNone
      |> List.sort ~cmp:String.compare
    in

    (* include parts of the current package metadata which contribute to the
      * build commands/environment *)
    let self =
      build
      |> Manifest.Build.to_yojson
      |> Yojson.Safe.to_string
    in

    (* a special tag which is communicated by the installer and specifies
      * the version of distribution of vcs commit sha *)
    let source =
      match source with
      | Some source -> Manifest.Source.show source
      | None -> "-"
    in

    let sandboxEnv =
      sandboxEnv
      |> Manifest.Env.to_yojson
      |> Yojson.Safe.to_string
    in

    String.concat "__" (sandboxEnv::source::self::dependencies)
    |> Digest.string
    |> Digest.to_hex
    |> fun hash -> String.sub hash 0 8
  in

  Printf.sprintf "%s-%s-%s"
    (Path.safeSeg build.name)
    (Path.safePath (Version.show build.version))
    hash

let make'
  ~platform
  ~buildConfig
  ~sandboxEnv
  ~solution
  ~installation
  ~manifests
  () =
  let open Run.Syntax in

  let tasks = ref PackageId.Map.empty in

  let rec aux record =
    let id = Package.id record in
    match PackageId.Map.find_opt id !tasks with
    | Some None -> return None
    | Some (Some build) -> return (Some build)
    | None ->
      let manifest = PackageId.Map.find id manifests in
      begin match Manifest.build manifest with
      | None -> return None
      | Some build ->
        let%bind build =
          Run.contextf
            (aux' id record build)
            "processing %a" PackageId.pp id
        in
        return (Some build)
      end

  and aux' pkgId record build =
    let location = Installation.findExn pkgId installation in
    let source, sourcePath, sourceType =
      match location with
      | Installation.Install info ->
        Some info.source, info.path, SourceType.Immutable
      | Installation.Link info ->
        None, info.path, SourceType.Transient
    in
    let%bind dependencies =
      let f (direct, record) =
        let%bind build = aux record in
        return (direct, build)
      in
      Result.List.map ~f (Solution.allDependenciesBFS record solution)
    in

    let id = buildId Manifest.Env.empty build source dependencies in
    let sourcePath = Sandbox.Path.ofPath buildConfig sourcePath in

    let exportedScope, buildScope =

      let sandboxEnv =
        let f {Manifest.Env. name; value} =
          Sandbox.Environment.Bindings.value name (Sandbox.Value.v value)
        in
        List.map ~f (StringMap.values sandboxEnv)
      in

      let exportedScope =
        Scope.make
          ~platform
          ~sandboxEnv
          ~id
          ~sourceType
          ~sourcePath
          ~buildIsInProgress:false
          build
      in

      let buildScope =
        Scope.make
          ~platform
          ~sandboxEnv
          ~id
          ~sourceType
          ~sourcePath
          ~buildIsInProgress:true
          build
      in

      let _, exportedScope, buildScope =
        let f (seen, exportedScope, buildScope) (direct, dep) =
          match dep with
          | None -> (seen, exportedScope, buildScope)
          | Some build ->
            if StringSet.mem build.Task.id seen
            then seen, exportedScope, buildScope
            else
              StringSet.add build.Task.id seen,
              Scope.add ~direct ~dep:build.exportedScope exportedScope,
              Scope.add ~direct ~dep:build.exportedScope buildScope
        in
        List.fold_left
          ~f
          ~init:(StringSet.empty, exportedScope, buildScope)
          dependencies
      in

      exportedScope, buildScope
    in

    let%bind buildEnv =
      let%bind bindings = Scope.env ~includeBuildEnv:true buildScope in
      Run.context
        (Run.ofStringError (Sandbox.Environment.Bindings.eval bindings))
        "evaluating environment"
    in

    let ocamlVersion = None in

    let opamEnv = Scope.toOpamEnv ~ocamlVersion buildScope in

    let%bind buildCommands =
      Run.context
        begin match build.buildCommands with
        | Manifest.Build.EsyCommands commands ->
          let%bind commands = renderEsyCommands ~env:buildEnv buildScope commands in
          let%bind applySubstsCommands = renderOpamSubstsAsCommands opamEnv build.substs in
          let%bind applyPatchesCommands = renderOpamPatchesToCommands opamEnv build.patches in
          return (applySubstsCommands @ applyPatchesCommands @ commands)
        | Manifest.Build.OpamCommands commands ->
          let%bind commands = renderOpamCommands opamEnv commands in
          let%bind applySubstsCommands = renderOpamSubstsAsCommands opamEnv build.substs in
          let%bind applyPatchesCommands = renderOpamPatchesToCommands opamEnv build.patches in
          return (applySubstsCommands @ applyPatchesCommands @ commands)
        end
        "processing esy.build"
    in

    let%bind installCommands =
      Run.context
        begin match build.installCommands with
        | Manifest.Build.EsyCommands commands ->
          renderEsyCommands ~env:buildEnv buildScope commands
        | Manifest.Build.OpamCommands commands ->
          renderOpamCommands opamEnv commands
        end
        "processing esy.install"
    in

    let task = {
      Task.
      id;
      pkgId;
      name = build.name;
      version = build.version;
      buildCommands;
      installCommands;
      env = buildEnv;
      buildType = build.buildType;
      sourceType;
      sourcePath;
      platform;
      exportedScope;
      buildScope;
    } in

    tasks := PackageId.Map.add (Package.id record) (Some task) !tasks;

    return task

  in

  let%bind (_ : Task.t option) = aux (Solution.root solution) in

  return !tasks

let make
  ~platform
  ~buildConfig
  ~sandboxEnv
  ~(solution : Solution.t)
  ~(installation : Installation.t) () =
  let open RunAsync.Syntax in
  let%bind _manifestsPath, manifests = readManifests installation in
  Logs_lwt.debug (fun m -> m "creating plan");%lwt
  let%bind tasks = RunAsync.ofRun (
    make'
      ~platform
      ~buildConfig
      ~sandboxEnv
      ~solution
      ~installation
      ~manifests
      ()
  ) in
  Logs_lwt.debug (fun m -> m "creating plan: done");%lwt
  return {tasks; solution;}

let findTaskById plan id =
  match PackageId.Map.find_opt id plan.tasks with
  | None -> Run.errorf "no such package %a" PackageId.pp id
  | Some task -> Run.return task

let findTaskByName plan name =
  let f _id pkg = pkg.Solution.Package.name = name in
  match Solution.find f plan.solution with
  | None -> None
  | Some (id, _) -> Some (PackageId.Map.find id plan.tasks)

let rootTask plan =
  let id = Solution.Package.id (Solution.root plan.solution) in
  PackageId.Map.find id plan.tasks

let shell ~buildConfig task =
  let plan = Task.plan task in
  EsyBuildPackageApi.buildShell ~buildConfig plan

let exec ~buildConfig task cmd =
  let plan = Task.plan task in
  EsyBuildPackageApi.buildExec ~buildConfig plan cmd

let build ?force ?quiet ?buildOnly ?logPath ~buildConfig task =
  Logs_lwt.debug (fun m -> m "build %a" PackageId.pp task.Task.pkgId);%lwt
  let plan = Task.plan task in
  EsyBuildPackageApi.build ?force ?quiet ?buildOnly ?logPath ~buildConfig plan

let buildDependencies ?(concurrency=1) ~buildConfig plan id =
  let open RunAsync.Syntax in
  Logs_lwt.debug (fun m -> m "buildDependencies ~concurrency:%i" concurrency);%lwt

  let queue = LwtTaskQueue.create ~concurrency () in
  let tasks = Hashtbl.create 100 in

  let isBuilt task =
    let installPath = Task.installPath task in
    let installPath = Sandbox.Path.toPath buildConfig installPath in
    Fs.exists installPath
  in

  let run task () =
    Logs_lwt.app (fun m -> m "building %a" PackageId.pp task.Task.pkgId);%lwt
    let logPath = Task.logPath task in
    let%bind () = build ~buildConfig ~logPath task in
    Logs_lwt.app (fun m -> m "building %a: done" PackageId.pp task.Task.pkgId);%lwt
    return ()
  in

  let runIfNeeded pkg =
    let id = Solution.Package.id pkg in
    match Hashtbl.find_opt tasks id with
    | Some running -> running
    | None ->
      begin match PackageId.Map.find id plan.tasks with
      | Some task ->
        let running =
          if%bind isBuilt task
          then return ()
          else LwtTaskQueue.submit queue (run task)
        in
        Hashtbl.replace tasks id running;
        running
      | None -> RunAsync.return ()
      end
  in

  let rec process pkg =
    let%bind () = processDependencies pkg in
    runIfNeeded pkg
  and processDependencies pkg =
    let dependencies = Solution.dependencies pkg plan.solution in
    let dependencies = StringMap.values dependencies in
    RunAsync.List.waitAll (List.map ~f:process dependencies)
  in

  match Solution.get id plan.solution with
  | None -> RunAsync.errorf "no such package %a" PackageId.pp id
  | Some pkg -> processDependencies pkg