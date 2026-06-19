defmodule LitterBox.Backends.Docker do
  @moduledoc """
  One-shot Docker CLI sandbox backend.

  The backend uses `docker run --rm` with explicit argv construction, disabled
  network by default, and a temporary copy-in workspace. It reports container
  isolation truth as metadata; Docker is useful isolation, but not a microVM.
  """

  @behaviour LitterBox.Backend

  import Bitwise, only: [band: 2]

  alias LitterBox.AttachEvents
  alias LitterBox.AttachHandle
  alias LitterBox.Capabilities
  alias LitterBox.Checkpoint
  alias LitterBox.Error
  alias LitterBox.ExecutionRequest
  alias LitterBox.ExecutionResult
  alias LitterBox.FileRef
  alias LitterBox.Instance
  alias LitterBox.Policy
  alias LitterBox.ProcessHandle
  alias LitterBox.ProcessStatus
  alias LitterBox.Profile
  alias LitterBox.Proxy
  alias LitterBox.Service
  alias LitterBox.Session

  @default_image "runic-ai/sandbox:elixir-python-node"
  @default_timeout_ms 30_000
  @runtime_commands %{
    bash: ["sh", "-lc"],
    sh: ["sh", "-lc"],
    python: ["python3", "-c"],
    node: ["node", "-e"],
    elixir: ["elixir", "-e"],
    lua: ["lua", "-e"]
  }

  @impl true
  def provision(%Profile{backend: backend} = profile, opts) when backend in [:docker, :gvisor] do
    metadata =
      %{
        security_boundary?: true,
        backend_module: __MODULE__,
        available?: exec_ready?(profile),
        host_available?: container_available?(profile),
        image_available?: image_available?(image(profile)),
        image: image(profile),
        container_runtime: container_runtime(profile),
        backend_options: profile.backend_options,
        policy: Policy.effective_network(profile.policy),
        stateful?: stateful?(profile)
      }
      |> maybe_put_stateful_workspace(profile)

    {:ok,
     Instance.from_profile(profile,
       id: Keyword.get(opts, :id),
       state: if(exec_ready?(profile), do: :ready, else: :unavailable),
       metadata: metadata
     )}
  end

  def provision(%Profile{} = profile, _opts) do
    {:error,
     Error.validation(
       "container backend cannot provision profile backend #{inspect(profile.backend)}",
       source: __MODULE__,
       details: %{backend: profile.backend}
     )}
  end

  @impl true
  def exec(%Instance{} = instance, %ExecutionRequest{} = request, _opts) do
    started_mono = System.monotonic_time(:millisecond)

    with :ok <- ensure_container_available(instance),
         {:ok, command} <- runtime_command(request),
         :ok <- ensure_workspace_supported(instance),
         {:ok, workspace_root, cleanup?} <- prepare_workspace(instance, request) do
      exec_in_workspace(instance, request, command, workspace_root, cleanup?, started_mono)
    end
  end

  defp exec_in_workspace(instance, request, command, workspace_root, cleanup?, started_mono) do
    try do
      with {:ok, before_files} <- snapshot_files(workspace_root),
           {:ok, output, exit_status, timed_out?} <-
             run_container(instance, request, command, workspace_root),
           {:ok, after_files} <- snapshot_files(workspace_root),
           {:ok, files_changed, artifacts} <-
             workspace_delta(workspace_root, before_files, after_files, request.max_output_bytes) do
        duration_ms = System.monotonic_time(:millisecond) - started_mono
        {stdout, stderr} = split_output(output)

        ExecutionResult.new(
          status: status(exit_status, timed_out?),
          stdout: cap(stdout, request.max_output_bytes),
          stderr: cap(stderr, request.max_output_bytes),
          exit_status: exit_status,
          duration_ms: duration_ms,
          files_changed: files_changed,
          artifacts: artifacts,
          backend: instance.backend,
          isolation_level: instance.isolation_level,
          diagnostics: diagnostics(output, request.max_output_bytes, timed_out?),
          resource_usage: %{},
          metadata: %{
            sandbox: request.sandbox,
            runtime: request.runtime,
            mode: request.mode,
            network: request.network,
            effective_network: effective_network_metadata(instance, request),
            image: image(instance),
            workspace_mode: instance.workspace.mode,
            workspace_mount: instance.workspace.mount,
            stateful?: stateful_instance?(instance),
            container_runtime: option(instance.metadata, :container_runtime),
            security_boundary?: true
          }
        )
      end
    after
      if cleanup?, do: File.rm_rf(workspace_root)
    end
  end

  @impl true
  def upload(%Instance{}, _files, _opts) do
    {:error,
     Error.validation("docker backend persistent upload is not supported", source: __MODULE__)}
  end

  @impl true
  def download(%Instance{}, _paths, _opts) do
    {:error,
     Error.validation("docker backend persistent download is not supported", source: __MODULE__)}
  end

  @impl true
  def snapshot(%Instance{} = instance, _opts) do
    {:ok,
     %{
       instance_id: instance.id,
       backend: instance.backend,
       stateful?: stateful_instance?(instance),
       container_runtime: option(instance.metadata, :container_runtime)
     }}
  end

  @impl true
  def reset(%Instance{}, _opts), do: :ok

  @impl true
  def destroy(%Instance{} = instance, _opts) do
    case option(instance.metadata, :workspace_root) do
      nil -> :ok
      workspace_root -> File.rm_rf(workspace_root)
    end
  end

  @impl true
  def health(opts) do
    profile = Keyword.get(opts, :profile)
    backend = if(profile, do: profile.backend, else: :docker)
    configured_image = image(profile)
    docker_available? = docker_available?()
    runsc_available? = runsc_available?()
    docker_runsc_runtime_available? = docker_runsc_runtime_available?()
    host_available? = container_available?(profile)
    image_available? = image_available?(configured_image)
    exec_ready? = host_available? and image_available?
    stateful? = if(profile, do: stateful?(profile), else: false)

    {:ok,
     %{
       name: backend,
       available?: exec_ready?,
       host_available?: host_available?,
       configured?: true,
       exec_ready?: exec_ready?,
       docker_available?: docker_available?,
       runsc_available?: runsc_available?,
       docker_runsc_runtime_available?: docker_runsc_runtime_available?,
       container_runtime: container_runtime(profile),
       image: configured_image,
       image_available?: image_available?,
       runtimes: [:bash, :sh, :python, :node, :elixir, :lua],
       isolation_level: isolation_level(backend),
       network: %{default: :disabled},
       stateful?: stateful?,
       security_boundary?: true,
       capabilities:
         Capabilities.to_map(
           Capabilities.new!(
             exec?: true,
             files?: false,
             inline_files?: true,
             artifacts?: true,
             session_files?: true,
             checkpoints?: true,
             services?: stateful?,
             proxy?: stateful?,
             leases?: false,
             streaming?: true,
             network_policy?: true,
             persistent_identity?: stateful?,
             metadata:
               docker_attach_metadata(
                 state_tier: if(stateful?, do: :persistent_process_host, else: :one_shot_exec),
                 process_host?: stateful?,
                 workspace_persistent?: stateful?,
                 service_host?: stateful?,
                 snapshot_modes: if(stateful?, do: [:filesystem], else: [])
               )
           )
         ),
       missing_requirements:
         docker_missing_requirements(
           backend,
           docker_available?,
           docker_runsc_runtime_available?,
           image_available?
         ),
       diagnostics:
         health_diagnostics(
           backend,
           docker_available?,
           docker_runsc_runtime_available?,
           image_available?,
           configured_image
         )
     }}
  end

  @impl true
  def open_session(%Profile{backend: backend} = profile, opts)
      when backend in [:docker, :gvisor] do
    session_profile = persistent_profile(profile)

    with {:ok, instance} <- provision(session_profile, opts),
         :ok <- ensure_container_available(instance),
         {:ok, workspace_root} <- session_workspace_root(instance),
         :ok <- File.mkdir_p(workspace_root),
         :ok <- maybe_seed_stateful_workspace(instance, workspace_root),
         :ok <- ensure_workspace_user_writable(workspace_root),
         {:ok, container} <- start_session_container(instance, workspace_root) do
      Session.from_instance(instance,
        capabilities:
          Capabilities.new!(
            exec?: true,
            files?: true,
            inline_files?: true,
            artifacts?: true,
            session_files?: true,
            checkpoints?: true,
            services?: true,
            proxy?: true,
            leases?: false,
            streaming?: true,
            network_policy?: true,
            persistent_identity?: true,
            metadata:
              docker_attach_metadata(
                state_tier: :persistent_process_host,
                process_host?: true,
                workspace_persistent?: true,
                service_host?: true,
                snapshot_modes: [:filesystem]
              )
          ),
        policy: session_profile.policy,
        state_model: :persistent_workspace,
        transport_model: if(backend == :gvisor, do: :docker_cli, else: :docker_cli),
        persistent_identity?: true,
        workspace_ref: "workspace://#{instance.id}",
        metadata: %{
          workspace_root: workspace_root,
          container_name: container.name,
          egress_resources: container.egress_resources,
          network: container.network
        }
      )
    end
  end

  @impl true
  def close_session(%Session{} = session, _opts) do
    cleanup_session_container(session)

    case session_workspace_root(session) do
      {:ok, workspace_root} ->
        File.rm_rf(workspace_root)
        :ok

      {:error, _error} ->
        :ok
    end
  end

  @impl true
  def exec_session(
        %Session{instance: %Instance{} = instance} = session,
        %ExecutionRequest{} = request,
        opts
      ) do
    case session_container_name(session) do
      {:ok, _container_name} ->
        exec_in_session_container(session, request)

      {:error, _error} ->
        exec(instance, request, opts)
    end
  end

  @impl true
  def attach_session(
        %Session{instance: %Instance{} = instance} = session,
        %ExecutionRequest{} = request,
        _opts
      ) do
    with :ok <- ensure_container_available(instance),
         {:ok, command} <- runtime_command(request),
         :ok <- ensure_workspace_supported(instance),
         {:ok, workspace_root, cleanup?} <- prepare_workspace(instance, request),
         {:ok, before_files} <- snapshot_files(workspace_root),
         {:ok, handle} <-
           open_container_attach(
             session,
             instance,
             request,
             command,
             workspace_root,
             cleanup?,
             before_files
           ) do
      {:ok, handle}
    end
  end

  @impl true
  def write_stdin(%AttachHandle{metadata: metadata}, input, _opts) do
    case Map.get(metadata, :port) do
      port when is_port(port) ->
        Port.command(port, IO.iodata_to_binary(input))
        :ok

      _other ->
        {:error,
         Error.validation("docker attach handle is not writable",
           source: __MODULE__,
           details: %{backend: :docker}
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  @impl true
  def close_attach(%AttachHandle{metadata: metadata}, _opts) do
    cleanup_attach(metadata)
    :ok
  end

  @impl true
  def start_process(%Session{} = session, %ExecutionRequest{} = request, _opts) do
    started_mono = System.monotonic_time(:millisecond)

    with {:ok, container_name} <- session_container_name(session),
         {:ok, command} <- runtime_command(request),
         {:ok, handle} <-
           open_session_process(session, request, container_name, command, started_mono) do
      {:ok, handle}
    end
  end

  @impl true
  def list_processes(%Session{} = session, _opts) do
    with {:ok, container_name} <- session_container_name(session),
         {:ok, output, 0} <-
           docker_cmd([
             "exec",
             container_name,
             "sh",
             "-lc",
             "ps -eo pid=,stat=,comm= 2>/dev/null || true"
           ]) do
      statuses =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&docker_process_status(session, &1))

      {:ok, statuses}
    else
      {:ok, output, exit_status} ->
        {:error,
         Error.validation("docker process listing failed",
           source: __MODULE__,
           details: %{exit_status: exit_status, output: output}
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def process_status(%Session{}, %ProcessHandle{} = handle, _opts) do
    case ProcessStatus.from_handle(handle) do
      {:ok, status} -> {:ok, status}
      {:error, error} -> {:error, error}
    end
  end

  def process_status(%Session{} = session, process_id, _opts) when is_binary(process_id) do
    ProcessStatus.new(
      id: process_id,
      session_id: session.id,
      backend: session.backend,
      status: :unknown
    )
  end

  @impl true
  def process_events(%ProcessHandle{} = handle, _opts), do: {:ok, ProcessHandle.events(handle)}

  @impl true
  def write_process_stdin(%ProcessHandle{metadata: metadata}, input, _opts) do
    case Map.get(metadata, :port) do
      port when is_port(port) ->
        Port.command(port, IO.iodata_to_binary(input))
        :ok

      _other ->
        {:error,
         Error.validation("docker process handle is not writable",
           source: __MODULE__,
           details: %{backend: :docker}
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  @impl true
  def close_process_stdin(%ProcessHandle{}, _opts) do
    {:error,
     Error.validation("docker process stdin close is not supported without a sidecar",
       source: __MODULE__,
       details: %{backend: :docker}
     )}
  end

  @impl true
  def signal_process(%ProcessHandle{metadata: metadata}, signal, _opts) do
    with container_name when is_binary(container_name) <- Map.get(metadata, :container_name),
         {:ok, pid} <- docker_process_pid(metadata),
         {:ok, _output, 0} <-
           docker_cmd(["exec", container_name, "kill", "-s", to_string(signal), pid]) do
      :ok
    else
      {:ok, output, exit_status} ->
        {:error,
         Error.validation("docker process signal failed",
           source: __MODULE__,
           details: %{exit_status: exit_status, output: output}
         )}

      _other ->
        {:error,
         Error.validation("docker process handle does not expose a signal target",
           source: __MODULE__,
           details: %{backend: :docker}
         )}
    end
  end

  @impl true
  def kill_process(%ProcessHandle{} = handle, opts) do
    case signal_process(handle, "TERM", opts) do
      :ok -> :ok
      {:error, _error} -> cleanup_process_handle(handle.metadata)
    end
  end

  @impl true
  def wait_process(%ProcessHandle{} = handle, _opts) do
    handle
    |> ProcessHandle.events()
    |> Enum.reduce(nil, fn
      %{type: :process_finished} = event, _acc -> event
      _event, acc -> acc
    end)
    |> case do
      %{payload: payload} ->
        ProcessStatus.from_handle(handle,
          status: docker_process_terminal_status(payload),
          exit_status: Map.get(payload, :exit_status)
        )

      nil ->
        ProcessStatus.from_handle(handle)
    end
  end

  @impl true
  def start_service(%Session{} = session, spec, _opts) do
    spec = spec_map(spec)
    name = option(spec, :name) || "service-#{System.unique_integer([:positive])}"
    id = "service-#{host_path_id(name)}-#{System.unique_integer([:positive])}"
    port = service_spec_port(spec)

    with {:ok, container_name} <- session_container_name(session),
         {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, command} <- service_shell_command(spec),
         :ok <- File.mkdir_p(service_registry_dir(workspace_root)) do
      pidfile = "/tmp/runic-sandbox-services/#{id}.pid"
      logfile = "/tmp/runic-sandbox-services/#{id}.log"

      script =
        "mkdir -p /tmp/runic-sandbox-services; " <>
          "(#{command}) > #{shell_escape(logfile)} 2>&1 & echo $! > #{shell_escape(pidfile)}"

      with {:ok, _output, 0} <- docker_cmd(["exec", container_name, "sh", "-lc", script]),
           {:ok, service} <-
             Service.new(
               id: id,
               session_id: session.id,
               name: to_string(name),
               status: :running,
               ports: service_ports(port),
               metadata: %{
                 container_name: container_name,
                 pidfile: pidfile,
                 logfile: logfile,
                 command: command,
                 port: port
               }
             ),
           :ok <- write_service_record(workspace_root, service),
           :ok <- wait_service_ready(session, service, spec) do
        {:ok, service}
      else
        {:ok, output, exit_status} ->
          {:error,
           Error.validation("docker service start failed",
             source: __MODULE__,
             details: %{exit_status: exit_status, output: output}
           )}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @impl true
  def stop_service(%Session{} = session, %Service{} = service, opts),
    do: stop_service(session, service.id, opts)

  def stop_service(%Session{} = session, service_id, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, service} <- read_service_record(workspace_root, to_string(service_id)),
         container_name when is_binary(container_name) <-
           Map.get(service.metadata, :container_name),
         pidfile when is_binary(pidfile) <- Map.get(service.metadata, :pidfile) do
      _ =
        docker_cmd([
          "exec",
          container_name,
          "sh",
          "-lc",
          "if [ -s #{shell_escape(pidfile)} ]; then kill $(cat #{shell_escape(pidfile)}) 2>/dev/null || true; fi"
        ])

      File.rm(service_record_path(workspace_root, service.id))
      :ok
    else
      {:error, error} -> {:error, error}
      _other -> :ok
    end
  end

  @impl true
  def list_services(%Session{} = session, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session) do
      services =
        workspace_root
        |> read_service_records()
        |> Enum.map(&refresh_service_status/1)

      {:ok, services}
    end
  end

  @impl true
  def open_proxy(%Session{} = session, %Service{} = service, opts),
    do: open_proxy(session, service.id, Keyword.put_new(opts, :port, service_port(service)))

  def open_proxy(%Session{} = session, service_id, opts) do
    target_port = Keyword.get(opts, :port) || 80
    local_port = Keyword.get(opts, :local_port, 0)

    with {:ok, container_name} <- session_container_name(session),
         {:ok, listen} <-
           :gen_tcp.listen(local_port, [
             :binary,
             active: false,
             packet: :raw,
             reuseaddr: true,
             ip: {127, 0, 0, 1}
           ]),
         {:ok, actual_port} <- :inet.port(listen) do
      id = "docker-proxy-#{session.id}-#{service_id}-#{actual_port}"
      pid = spawn(fn -> docker_proxy_accept_loop(listen, container_name, target_port) end)
      put_proxy_record(id, %{session_id: session.id, listener: listen, pid: pid})

      Proxy.new(
        id: id,
        session_id: session.id,
        backend: session.backend,
        service_id: to_string(service_id),
        status: :open,
        url: "http://127.0.0.1:#{actual_port}",
        local_port: actual_port,
        metadata: %{
          provider: :docker,
          host: "127.0.0.1",
          port: target_port,
          local_only?: true,
          container_name: container_name
        }
      )
    else
      {:error, reason} when is_atom(reason) ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to open docker service proxy"
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def close_proxy(%Proxy{} = proxy, _opts) do
    close_proxy_record(proxy.id)
    :ok
  end

  def close_proxy(_proxy, _opts), do: :ok

  @impl true
  def write_file(%Session{} = session, path, contents, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, full_path} <- safe_workspace_path(workspace_root, path),
         :ok <- ensure_no_symlink_path(workspace_root, full_path),
         :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.write(full_path, contents),
         {:ok, ref} <- file_ref(workspace_root, full_path) do
      {:ok, ref}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to write docker session file"
         )}
    end
  end

  @impl true
  def read_file(%Session{} = session, path, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, full_path} <- safe_workspace_path(workspace_root, path),
         :ok <- ensure_no_symlink_path(workspace_root, full_path),
         :ok <- ensure_regular_file(full_path) do
      File.read(full_path)
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to read docker session file"
         )}
    end
  end

  @impl true
  def list_files(%Session{} = session, path, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, full_path} <- safe_workspace_path(workspace_root, path),
         :ok <- ensure_no_symlink_path(workspace_root, full_path),
         true <- File.exists?(full_path) do
      refs =
        cond do
          regular_directory?(full_path) ->
            full_path
            |> walk_files()
            |> Enum.map(fn file -> file_ref!(workspace_root, file) end)

          regular_file?(full_path) ->
            [file_ref!(workspace_root, full_path)]

          true ->
            []
        end

      {:ok, refs}
    else
      false ->
        {:ok, []}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to list docker session files"
         )}
    end
  end

  @impl true
  def delete_file(%Session{} = session, path, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, full_path} <- safe_workspace_path(workspace_root, path),
         :ok <- ensure_no_symlink_path(workspace_root, full_path) do
      case File.rm_rf(full_path) do
        {:ok, _paths} -> :ok
        {:error, reason, _path} -> {:error, Error.from_reason(reason, source: __MODULE__)}
      end
    end
  end

  @impl true
  def checkpoint(%Session{} = session, spec, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, checkpoint_root} <- checkpoint_workspace_root(session, spec),
         :ok <- replace_directory(checkpoint_root),
         :ok <- copy_directory_contents(workspace_root, checkpoint_root) do
      checkpoint_id = Path.basename(checkpoint_root)
      ref = "checkpoint://#{session.id}/#{checkpoint_id}"

      metadata = %{
        kind: :filesystem,
        path: checkpoint_root,
        preserves: Checkpoint.preserves(:filesystem),
        caveats: [
          "Docker filesystem checkpoints preserve files only; running processes, service runtime state, and open TCP connections are not restored."
        ]
      }

      Checkpoint.new(
        id: checkpoint_id,
        session_id: session.id,
        backend: session.backend,
        ref: ref,
        created_at: DateTime.utc_now(),
        metadata:
          Map.put(
            metadata,
            :authority,
            checkpoint_authority(session, checkpoint_id, ref, metadata)
          )
      )
    end
  end

  @impl true
  def restore(%Session{} = session, %Checkpoint{} = checkpoint, _opts) do
    with :ok <- validate_checkpoint(session, checkpoint),
         {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, checkpoint_root} <- checkpoint_path(checkpoint),
         :ok <- verify_checkpoint_authority(session, checkpoint),
         :ok <- ensure_no_symlink_tree(checkpoint_root),
         :ok <- replace_directory(workspace_root),
         :ok <- copy_directory_contents(checkpoint_root, workspace_root) do
      {:ok, session}
    end
  end

  def restore(%Session{}, _checkpoint, _opts) do
    {:error,
     Error.validation("docker session restore requires a filesystem checkpoint",
       source: __MODULE__
     )}
  end

  defp persistent_profile(%Profile{} = profile) do
    workspace = %{profile.workspace | persist?: true}
    %{profile | stateful?: true, workspace: workspace}
  end

  defp maybe_seed_stateful_workspace(%Instance{workspace: %{host_root: nil}}, _workspace_root),
    do: :ok

  defp maybe_seed_stateful_workspace(
         %Instance{workspace: %{host_root: host_root}},
         workspace_root
       )
       when is_binary(host_root) do
    seed_workspace_from_host_root(host_root, workspace_root)
  end

  defp seed_workspace_from_host_root(host_root, workspace_root) do
    host_root = Path.expand(host_root)

    with :ok <- ensure_seed_host_root(host_root),
         {:ok, entries} <- File.ls(host_root),
         :ok <- copy_seed_entries(entries, host_root, workspace_root) do
      :ok
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to seed docker workspace from host_root",
           details: %{host_root: host_root, workspace_root: workspace_root}
         )}
    end
  end

  defp ensure_seed_host_root(host_root) do
    case File.lstat(host_root) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, stat} ->
        {:error,
         Error.validation("docker workspace host_root must be an existing directory",
           source: __MODULE__,
           details: %{host_root: host_root, type: stat.type}
         )}

      {:error, reason} ->
        {:error,
         Error.validation("docker workspace host_root must be an existing directory",
           source: __MODULE__,
           details: %{host_root: host_root, reason: reason}
         )}
    end
  end

  defp copy_seed_entries(entries, host_root, workspace_root) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      source_path = Path.join(host_root, entry)
      destination_path = Path.join(workspace_root, entry)

      case File.cp_r(source_path, destination_path) do
        {:ok, _paths} ->
          {:cont, :ok}

        {:error, reason, path} ->
          {:halt,
           {:error,
            Error.from_reason(reason,
              source: __MODULE__,
              message: "failed to seed docker workspace from host_root",
              details: %{host_root: host_root, workspace_root: workspace_root, path: path}
            )}}
      end
    end)
  end

  defp ensure_workspace_user_writable(workspace_root) do
    make_path_user_writable(workspace_root)
  end

  defp make_path_user_writable(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        with :ok <- File.chmod(path, 0o777),
             {:ok, entries} <- File.ls(path) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case make_path_user_writable(Path.join(path, entry)) do
              :ok -> {:cont, :ok}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)
        else
          {:error, reason} -> workspace_chmod_error(reason, path)
        end

      {:ok, %{type: :regular, mode: mode}} ->
        mode =
          if band(mode, 0o111) == 0 do
            0o666
          else
            0o777
          end

        case File.chmod(path, mode) do
          :ok -> :ok
          {:error, reason} -> workspace_chmod_error(reason, path)
        end

      {:ok, _stat} ->
        :ok

      {:error, reason} ->
        workspace_chmod_error(reason, path)
    end
  end

  defp workspace_chmod_error(reason, path) do
    {:error,
     Error.from_reason(reason,
       source: __MODULE__,
       message: "failed to prepare docker workspace permissions",
       details: %{path: path}
     )}
  end

  defp session_workspace_root(%Session{} = session) do
    case option(session.metadata, :workspace_root) do
      workspace_root when is_binary(workspace_root) and workspace_root != "" ->
        {:ok, workspace_root}

      _other ->
        session.instance
        |> session_workspace_root()
    end
  end

  defp session_workspace_root(%Instance{} = instance) do
    case option(instance.metadata, :workspace_root) do
      workspace_root when is_binary(workspace_root) and workspace_root != "" ->
        {:ok, workspace_root}

      _other ->
        {:error,
         Error.validation("docker session does not have a managed workspace",
           source: __MODULE__,
           details: %{instance_id: instance.id, backend: instance.backend}
         )}
    end
  end

  defp session_workspace_root(_other) do
    {:error,
     Error.validation("docker session does not have an instance",
       source: __MODULE__
     )}
  end

  defp session_container_name(%Session{} = session) do
    case option(session.metadata, :container_name) do
      container_name when is_binary(container_name) and container_name != "" ->
        {:ok, container_name}

      _other ->
        {:error,
         Error.validation("docker session does not have a managed container",
           source: __MODULE__,
           details: %{session_id: session.id, backend: session.backend}
         )}
    end
  end

  defp start_session_container(%Instance{} = instance, workspace_root) do
    container_name = "runic-sandbox-session-#{System.unique_integer([:positive])}"

    with {:ok, network} <- docker_session_network_setup(instance),
         {:ok, _output, 0} <-
           docker_cmd(
             [
               "run",
               "-d",
               "--pull",
               "never",
               "--name",
               container_name,
               "--workdir",
               instance.workspace.mount
             ] ++
               network.args ++
               [
                 "--mount",
                 "type=bind,src=#{workspace_root},dst=#{instance.workspace.mount}"
               ] ++
               env_args(instance) ++
               runtime_args(instance) ++
               security_args(instance) ++
               resource_args(instance) ++
               [
                 image(instance),
                 "sh",
                 "-lc",
                 "trap 'exit 0' TERM INT; while true; do sleep 3600; done"
               ],
             network.resources
           ) do
      {:ok,
       %{name: container_name, egress_resources: network.resources, network: network.metadata}}
    else
      {:ok, output, exit_status} ->
        cleanup_egress_resources(network_resources_from_error(output))

        {:error,
         Error.validation("failed to start docker session container",
           source: __MODULE__,
           details: %{exit_status: exit_status, output: output}
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp cleanup_session_container(%Session{} = session) do
    cleanup_session_proxies(session.id)

    case option(session.metadata, :container_name) do
      container_name when is_binary(container_name) ->
        System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)

      _other ->
        :ok
    end

    cleanup_egress_resources(option(session.metadata, :egress_resources) || [])

    case session_workspace_root(session) do
      {:ok, workspace_root} -> File.rm_rf(service_registry_dir(workspace_root))
      {:error, _error} -> :ok
    end

    :ok
  rescue
    _exception -> :ok
  end

  defp network_resources_from_error(_output), do: []

  defp service_registry_dir(workspace_root),
    do: Path.join(workspace_root, ".litter_box/services")

  defp service_record_path(workspace_root, service_id) do
    Path.join(service_registry_dir(workspace_root), "#{host_path_id(service_id)}.json")
  end

  defp write_service_record(workspace_root, %Service{} = service) do
    record = %{
      id: service.id,
      session_id: service.session_id,
      name: service.name,
      status: Atom.to_string(service.status),
      ports: service.ports,
      metadata: service.metadata
    }

    with {:ok, json} <- Jason.encode(record),
         :ok <- File.write(service_record_path(workspace_root, service.id), json) do
      :ok
    else
      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to write docker service record"
         )}
    end
  end

  defp read_service_record(workspace_root, service_id) do
    with {:ok, json} <- File.read(service_record_path(workspace_root, service_id)),
         {:ok, record} <- Jason.decode(json) do
      Service.new(
        id: option(record, :id, nil),
        session_id: option(record, :session_id, nil),
        name: option(record, :name, nil),
        status: option(record, :status, :running),
        ports: option(record, :ports, []),
        metadata: atomize_known_service_metadata(option(record, :metadata, %{}))
      )
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, Error.from_exception(error, source: __MODULE__)}

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to read docker service record"
         )}
    end
  end

  defp read_service_records(workspace_root) do
    dir = service_registry_dir(workspace_root)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.flat_map(fn name ->
          path = Path.join(dir, name)

          case File.read(path) do
            {:ok, json} ->
              case Jason.decode(json) do
                {:ok, record} ->
                  case Service.new(
                         id: option(record, :id, nil),
                         session_id: option(record, :session_id, nil),
                         name: option(record, :name, nil),
                         status: option(record, :status, :running),
                         ports: option(record, :ports, []),
                         metadata: atomize_known_service_metadata(option(record, :metadata, %{}))
                       ) do
                    {:ok, service} -> [service]
                    {:error, _error} -> []
                  end

                {:error, _error} ->
                  []
              end

            {:error, _reason} ->
              []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp atomize_known_service_metadata(metadata) when is_map(metadata) do
    %{
      container_name: option(metadata, :container_name, nil),
      pidfile: option(metadata, :pidfile, nil),
      logfile: option(metadata, :logfile, nil),
      command: option(metadata, :command, nil),
      port: option(metadata, :port, nil)
    }
  end

  defp refresh_service_status(%Service{} = service) do
    container_name = service.metadata.container_name
    pidfile = service.metadata.pidfile

    status =
      case docker_cmd([
             "exec",
             container_name,
             "sh",
             "-lc",
             "test -s #{shell_escape(pidfile)} && kill -0 $(cat #{shell_escape(pidfile)})"
           ]) do
        {:ok, _output, 0} -> :running
        _other -> :stopped
      end

    %{service | status: status}
  end

  defp service_shell_command(spec) do
    cond do
      command = option(spec, :command) ->
        shell_command(command, option(spec, :args) || [])

      cmd = option(spec, :cmd) ->
        shell_command(cmd, option(spec, :args) || [])

      true ->
        {:error,
         Error.validation("docker service requires command or cmd",
           source: __MODULE__,
           details: %{spec: Map.drop(spec, [:env])}
         )}
    end
  end

  defp shell_command(command, args) when is_list(command) and args == [] do
    {:ok, Enum.map_join(command, " ", &shell_escape/1)}
  end

  defp shell_command(command, args) when is_binary(command) and is_list(args) do
    {:ok, Enum.map_join([command | args], " ", &shell_escape/1)}
  end

  defp shell_command(command, _args) when is_binary(command), do: {:ok, command}

  defp shell_command(command, args) do
    {:error,
     Error.validation("docker service command must be a string or argv list",
       source: __MODULE__,
       details: %{command: command, args: args}
     )}
  end

  defp service_spec_port(spec), do: option(spec, :port) || option(spec, :http_port)

  defp service_ports(nil), do: []
  defp service_ports(port), do: [%{port: port, protocol: "tcp"}]

  defp service_port(%Service{ports: [%{port: port} | _]}), do: port
  defp service_port(%Service{ports: [%{"port" => port} | _]}), do: port
  defp service_port(%Service{metadata: metadata}), do: option(metadata, :port) || 80

  defp wait_service_ready(%Session{} = session, %Service{} = service, spec) do
    case option(spec, :readiness) || option(spec, :readiness_probe) do
      nil ->
        :ok

      readiness ->
        readiness = spec_map(readiness)
        timeout_ms = option(readiness, :timeout_ms) || 5_000
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        wait_service_ready(session, service, readiness, deadline)
    end
  end

  defp wait_service_ready(%Session{} = session, %Service{} = service, readiness, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error,
       Error.validation("docker service readiness probe timed out",
         source: __MODULE__,
         details: %{service_id: service.id, readiness: readiness}
       )}
    else
      case service_ready?(session, service, readiness) do
        true ->
          :ok

        false ->
          Process.sleep(option(readiness, :interval_ms) || 100)
          wait_service_ready(session, service, readiness, deadline)
      end
    end
  end

  defp service_ready?(%Session{} = session, %Service{} = service, readiness) do
    with {:ok, container_name} <- session_container_name(session) do
      port = option(readiness, :port) || service_port(service)
      path = option(readiness, :path) || "/"

      script =
        case option(readiness, :type) || :tcp do
          type when type in [:http, "http"] ->
            "python3 - <<'PY'\n" <>
              "import urllib.request\n" <>
              "urllib.request.urlopen('http://127.0.0.1:#{port}#{path}', timeout=1).read()\n" <>
              "PY"

          _tcp ->
            "python3 - <<'PY'\n" <>
              "import socket\n" <>
              "socket.create_connection(('127.0.0.1', #{port}), timeout=1).close()\n" <>
              "PY"
        end

      case docker_cmd(["exec", container_name, "sh", "-lc", script]) do
        {:ok, _output, 0} -> true
        _other -> false
      end
    else
      _other -> false
    end
  end

  defp docker_proxy_accept_loop(listen, container_name, target_port) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> docker_proxy_connection(socket, container_name, target_port) end)
        docker_proxy_accept_loop(listen, container_name, target_port)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp docker_proxy_connection(socket, container_name, target_port) do
    with {:ok, request} <- recv_http_proxy_request(socket, ""),
         {:ok, method, path} <- parse_http_proxy_request(request),
         {:ok, response, 0} <-
           docker_cmd([
             "exec",
             container_name,
             "python3",
             "-u",
             "-c",
             docker_http_proxy_client_script(),
             to_string(target_port),
             method,
             path
           ]) do
      :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
    else
      _error ->
        :gen_tcp.close(socket)
    end
  end

  defp recv_http_proxy_request(_socket, acc) when byte_size(acc) > 65_536,
    do: {:error, :request_too_large}

  defp recv_http_proxy_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, chunk} -> recv_http_proxy_request(socket, acc <> chunk)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_http_proxy_request(request) do
    request
    |> String.split("\r\n", parts: 2)
    |> hd()
    |> String.split(" ", parts: 3)
    |> case do
      [method, path, "HTTP/" <> _version] -> {:ok, method, path}
      _other -> {:error, :invalid_http_request}
    end
  end

  defp docker_http_proxy_client_script do
    """
    import socket
    import sys

    port = int(sys.argv[1])
    method = sys.argv[2]
    path = sys.argv[3]
    request = f"{method} {path} HTTP/1.1\\r\\nhost: 127.0.0.1\\r\\nconnection: close\\r\\n\\r\\n".encode()
    upstream = socket.create_connection(("127.0.0.1", port), timeout=10)
    upstream.sendall(request)

    while True:
        data = upstream.recv(65536)
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    """
  end

  defp proxy_table do
    table = :litter_box_docker_proxies

    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        table
    end
  end

  defp put_proxy_record(id, record) do
    :ets.insert(proxy_table(), {id, record})
    :ok
  end

  defp close_proxy_record(id) do
    case :ets.lookup(proxy_table(), id) do
      [{^id, %{listener: listener, pid: pid}}] ->
        :gen_tcp.close(listener)
        if is_pid(pid), do: Process.exit(pid, :normal)
        :ets.delete(proxy_table(), id)
        :ok

      _other ->
        :ok
    end
  end

  defp cleanup_session_proxies(session_id) do
    proxy_table()
    |> :ets.match_object({:_, %{session_id: session_id, listener: :_, pid: :_}})
    |> Enum.each(fn {id, _record} -> close_proxy_record(id) end)
  end

  defp spec_map(value) when is_map(value), do: value
  defp spec_map(value) when is_list(value), do: Map.new(value)
  defp spec_map(_value), do: %{}

  defp file_ref!(workspace_root, full_path) do
    {:ok, ref} = file_ref(workspace_root, full_path)
    ref
  end

  defp file_ref(workspace_root, full_path) do
    relative = Path.relative_to(full_path, workspace_root)

    with :ok <- ensure_no_symlink_path(workspace_root, full_path),
         :ok <- ensure_regular_file(full_path),
         {:ok, stat} <- File.lstat(full_path),
         {:ok, content} <- File.read(full_path) do
      FileRef.new(
        path: relative,
        kind: :file,
        bytes: stat.size,
        sha256: Base.encode16(:crypto.hash(:sha256, content), case: :lower)
      )
    end
  end

  defp checkpoint_workspace_root(%Session{} = session, spec) do
    spec = if is_list(spec), do: Map.new(spec), else: Map.new(spec || %{})
    session_path_id = host_path_id(session.id)

    checkpoint_id =
      spec
      |> Map.get(:id, Map.get(spec, "id"))
      |> normalize_checkpoint_id()

    {:ok,
     Path.join(
       host_tmp_dir(),
       "litter_box_checkpoint_#{session_path_id}_#{checkpoint_id}"
     )}
  end

  defp normalize_checkpoint_id(nil), do: "checkpoint_#{System.unique_integer([:positive])}"

  defp normalize_checkpoint_id(id), do: host_path_id(id)

  defp host_path_id(nil), do: "id_#{System.unique_integer([:positive])}"

  defp host_path_id(id) do
    id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "_")
    |> String.trim("._-")
    |> case do
      "" -> "checkpoint_#{System.unique_integer([:positive])}"
      sanitized -> sanitized
    end
  end

  defp validate_checkpoint(%Session{} = session, %Checkpoint{} = checkpoint) do
    cond do
      checkpoint.session_id != session.id ->
        {:error,
         Error.validation("checkpoint belongs to a different sandbox session",
           source: __MODULE__,
           details: %{checkpoint_session_id: checkpoint.session_id, session_id: session.id}
         )}

      checkpoint.backend != session.backend ->
        {:error,
         Error.validation("checkpoint belongs to a different sandbox backend",
           source: __MODULE__,
           details: %{checkpoint_backend: checkpoint.backend, session_backend: session.backend}
         )}

      checkpoint.metadata[:kind] != :filesystem ->
        {:error,
         Error.validation("docker restore only supports filesystem checkpoints",
           source: __MODULE__,
           details: %{kind: checkpoint.metadata[:kind]}
         )}

      true ->
        :ok
    end
  end

  defp checkpoint_authority(%Session{} = session, checkpoint_id, ref, metadata) do
    snapshot = checkpoint_snapshot(session, checkpoint_id, ref, metadata)
    %{version: 1, signature: checkpoint_signature(snapshot)}
  end

  defp verify_checkpoint_authority(%Session{} = session, %Checkpoint{} = checkpoint) do
    case checkpoint.metadata[:authority] do
      %{version: 1, signature: signature} when is_binary(signature) ->
        metadata = Map.delete(checkpoint.metadata, :authority)
        snapshot = checkpoint_snapshot(session, checkpoint.id, checkpoint.ref, metadata)

        if secure_equal?(signature, checkpoint_signature(snapshot)) do
          :ok
        else
          checkpoint_authority_error(checkpoint, "docker checkpoint authority does not match")
        end

      _other ->
        checkpoint_authority_error(checkpoint, "docker checkpoint authority is missing")
    end
  end

  defp checkpoint_snapshot(%Session{} = session, checkpoint_id, ref, metadata) do
    %{
      id: checkpoint_id,
      session_id: session.id,
      backend: session.backend,
      ref: ref,
      metadata: metadata
    }
  end

  defp checkpoint_signature(snapshot) do
    :hmac
    |> :crypto.mac(:sha256, checkpoint_authority_secret(), :erlang.term_to_binary(snapshot))
    |> Base.encode16(case: :lower)
  end

  defp checkpoint_authority_secret do
    key = {__MODULE__, :checkpoint_authority_secret}

    case :persistent_term.get(key, nil) do
      nil ->
        secret = :crypto.strong_rand_bytes(32)
        :persistent_term.put(key, secret)
        secret

      secret ->
        secret
    end
  end

  defp checkpoint_authority_error(%Checkpoint{} = checkpoint, message) do
    {:error,
     Error.validation(message,
       source: __MODULE__,
       details: %{checkpoint_id: checkpoint.id, session_id: checkpoint.session_id}
     )}
  end

  defp checkpoint_path(%Checkpoint{} = checkpoint) do
    path = checkpoint.metadata[:path]

    cond do
      not is_binary(path) or path == "" ->
        {:error,
         Error.validation("filesystem checkpoint is missing a path",
           source: __MODULE__,
           details: %{checkpoint_id: checkpoint.id}
         )}

      not String.starts_with?(Path.expand(path), Path.expand(host_tmp_dir()) <> "/") ->
        {:error,
         Error.validation("filesystem checkpoint path is outside the managed checkpoint root",
           source: __MODULE__,
           details: %{checkpoint_id: checkpoint.id}
         )}

      true ->
        {:ok, path}
    end
  end

  defp replace_directory(path) do
    File.rm_rf(path)
    File.mkdir_p(path)
  end

  defp copy_directory_contents(source_root, destination_root) do
    source_root
    |> walk_files()
    |> Enum.reduce_while(:ok, fn source_path, :ok ->
      relative = Path.relative_to(source_path, source_root)
      destination_path = Path.join(destination_root, relative)

      with :ok <- File.mkdir_p(Path.dirname(destination_path)),
           {:ok, _bytes} <- File.copy(source_path, destination_path) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt,
           {:error,
            Error.from_reason(reason,
              source: __MODULE__,
              message: "failed to copy docker session filesystem"
            )}}
      end
    end)
  end

  defp run_container(
         %Instance{} = instance,
         %ExecutionRequest{} = request,
         command,
         workspace_root
       ) do
    container_name = "runic-sandbox-#{System.unique_integer([:positive])}"

    with {:ok, network} <- docker_network_setup(instance, request) do
      args =
        [
          "run",
          "--rm",
          "--pull",
          "never",
          "--name",
          container_name,
          "--workdir",
          request.cwd
        ] ++
          network.args ++
          [
            "--mount",
            "type=bind,src=#{workspace_root},dst=#{instance.workspace.mount}"
          ] ++
          env_args(instance) ++
          runtime_args(instance) ++
          security_args(instance) ++ resource_args(instance) ++ [image(instance) | command]

      try do
        invoke_docker(args, request.timeout_ms || @default_timeout_ms, container_name)
      after
        cleanup_egress_resources(network.resources)
      end
    end
  end

  defp exec_in_session_container(%Session{} = session, %ExecutionRequest{} = request) do
    started_mono = System.monotonic_time(:millisecond)

    with {:ok, container_name} <- session_container_name(session),
         {:ok, command} <- runtime_command(request),
         {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, before_files} <- snapshot_files(workspace_root),
         {:ok, output, exit_status, timed_out?} <-
           invoke_docker_session_exec(container_name, request, command),
         {:ok, after_files} <- snapshot_files(workspace_root),
         {:ok, files_changed, artifacts} <-
           workspace_delta(workspace_root, before_files, after_files, request.max_output_bytes) do
      duration_ms = System.monotonic_time(:millisecond) - started_mono
      {stdout, stderr} = split_output(output)

      ExecutionResult.new(
        status: status(exit_status, timed_out?),
        stdout: cap(stdout, request.max_output_bytes),
        stderr: cap(stderr, request.max_output_bytes),
        exit_status: exit_status,
        duration_ms: duration_ms,
        files_changed: files_changed,
        artifacts: artifacts,
        backend: session.backend,
        isolation_level: session.isolation_level,
        diagnostics: diagnostics(output, request.max_output_bytes, timed_out?),
        resource_usage: %{},
        metadata: %{
          sandbox: request.sandbox,
          runtime: request.runtime,
          mode: request.mode,
          network: request.network,
          effective_network: Map.get(session.metadata, :network),
          image: image(session.instance),
          workspace_mode: session.instance.workspace.mode,
          workspace_mount: session.instance.workspace.mount,
          stateful?: true,
          container_name: container_name,
          container_runtime: option(session.instance.metadata, :container_runtime),
          security_boundary?: true
        }
      )
    end
  end

  defp invoke_docker_session_exec(container_name, %ExecutionRequest{} = request, command) do
    args = ["exec", "--workdir", request.cwd, container_name] ++ command
    invoke_docker_exec(args, request.timeout_ms || @default_timeout_ms)
  end

  defp open_container_attach(
         %Session{} = session,
         %Instance{} = instance,
         %ExecutionRequest{} = request,
         command,
         workspace_root,
         cleanup?,
         before_files
       ) do
    container_name = "runic-sandbox-attach-#{System.unique_integer([:positive])}"
    started_mono = System.monotonic_time(:millisecond)

    with {:ok, network} <- docker_network_setup(instance, request) do
      args =
        [
          "run",
          "--rm",
          "--pull",
          "never",
          "-i",
          "--name",
          container_name,
          "--workdir",
          request.cwd
        ] ++
          network.args ++
          [
            "--mount",
            "type=bind,src=#{workspace_root},dst=#{instance.workspace.mount}"
          ] ++
          env_args(instance) ++
          runtime_args(instance) ++
          security_args(instance) ++ resource_args(instance) ++ [image(instance) | command]

      case open_docker_port(args) do
        {:ok, port} ->
          container_attach_handle(
            session,
            request,
            port,
            container_name,
            workspace_root,
            cleanup?,
            before_files,
            started_mono,
            network
          )

        {:error, error} ->
          cleanup_egress_resources(network.resources)
          {:error, error}
      end
    end
  end

  defp open_session_process(
         %Session{} = session,
         %ExecutionRequest{} = request,
         container_name,
         command,
         started_mono
       ) do
    process_id = "process-#{System.unique_integer([:positive])}"
    pidfile = "/tmp/runic-sandbox-#{process_id}.pid"

    args =
      ["exec", "-i", "--workdir", request.cwd] ++
        env_args(session.instance) ++
        [container_name] ++
        [
          "sh",
          "-lc",
          "printf '%s' \"$$\" > \"$1\"; shift; exec \"$@\"",
          "runic-process",
          pidfile
        ] ++ command

    case open_docker_port(args) do
      {:ok, port} ->
        if request.stdin != "", do: Port.command(port, request.stdin)

        events =
          Stream.resource(
            fn ->
              %{
                session: session,
                request: request,
                port: port,
                process_id: process_id,
                container_name: container_name,
                started?: false,
                finished?: false,
                started_mono: started_mono
              }
            end,
            &next_process_event/1,
            &cleanup_process_stream/1
          )

        ProcessHandle.new(
          id: process_id,
          session_id: session.id,
          backend: session.backend,
          status: :running,
          command: command,
          events: events,
          metadata: %{
            streaming_live?: true,
            port: port,
            container_name: container_name,
            process_id: process_id,
            pidfile: pidfile
          }
        )

      {:error, error} ->
        {:error, error}
    end
  end

  defp next_process_event(%{started?: false} = state) do
    event =
      AttachEvents.event(state.session, :process_started, %{
        process_id: state.process_id,
        runtime: state.request.runtime,
        mode: state.request.mode,
        argv: state.request.argv,
        cwd: state.request.cwd,
        container_name: state.container_name
      })

    {[event], %{state | started?: true}}
  end

  defp next_process_event(%{port: port} = state) do
    receive do
      {^port, {:data, data}} ->
        event =
          AttachEvents.chunk_event(
            state.session,
            :stdout_chunk,
            cap(data, state.request.max_output_bytes)
          )

        {[event], state}

      {^port, {:exit_status, exit_status}} ->
        state = %{state | finished?: true}
        event = docker_process_finished_event(state, exit_status)
        cleanup_process_stream(state)
        {[event], :halt}
    end
  end

  defp next_process_event(:halt), do: {:halt, :halt}

  defp docker_process_finished_event(state, exit_status) do
    duration_ms = System.monotonic_time(:millisecond) - state.started_mono

    AttachEvents.event(state.session, :process_finished, %{
      process_id: state.process_id,
      status: status(exit_status, false),
      exit_status: exit_status,
      duration_ms: duration_ms,
      container_name: state.container_name
    })
  end

  defp cleanup_process_stream(:halt), do: :ok

  defp cleanup_process_stream(%{finished?: finished?} = state) do
    unless finished? do
      cleanup_process_handle(%{port: state.port})
    end

    :ok
  end

  defp cleanup_process_handle(%{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    _exception -> :ok
  end

  defp cleanup_process_handle(_metadata), do: :ok

  defp docker_process_pid(metadata) do
    with container_name when is_binary(container_name) <- Map.get(metadata, :container_name),
         pidfile when is_binary(pidfile) <- Map.get(metadata, :pidfile),
         {:ok, output, 0} <- docker_cmd(["exec", container_name, "cat", pidfile]),
         pid when pid != "" <- String.trim(output) do
      {:ok, pid}
    else
      {:ok, output, exit_status} ->
        {:error,
         Error.validation("docker process pid lookup failed",
           source: __MODULE__,
           details: %{exit_status: exit_status, output: output}
         )}

      _other ->
        {:error,
         Error.validation("docker process handle does not expose a pidfile",
           source: __MODULE__,
           details: %{backend: :docker}
         )}
    end
  end

  defp container_attach_handle(
         %Session{} = session,
         %ExecutionRequest{} = request,
         port,
         container_name,
         workspace_root,
         cleanup?,
         before_files,
         started_mono,
         network
       ) do
    if request.stdin != "", do: Port.command(port, request.stdin)

    events =
      Stream.resource(
        fn ->
          timer_ref = attach_timer(request.timeout_ms, port, container_name)

          %{
            session: session,
            request: request,
            port: port,
            timer_ref: timer_ref,
            container_name: container_name,
            workspace_root: workspace_root,
            cleanup?: cleanup?,
            before_files: before_files,
            egress_resources: network.resources,
            network_metadata: network.metadata,
            started?: false,
            finished?: false,
            started_mono: started_mono
          }
        end,
        &next_attach_event/1,
        &cleanup_attach_stream/1
      )

    AttachHandle.new(
      id: AttachEvents.attach_id(),
      session_id: session.id,
      backend: session.backend,
      events: events,
      metadata: %{
        streaming_live?: true,
        terminal_result?: false,
        port: port,
        container_name: container_name,
        workspace_root: workspace_root,
        cleanup?: cleanup?,
        egress_resources: network.resources,
        network: network.metadata
      }
    )
  end

  defp open_docker_port(args) do
    executable = System.find_executable("docker") || "docker"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    {:ok, port}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp attach_timer(:infinity, _port, _container_name), do: nil

  defp attach_timer(nil, port, container_name),
    do: attach_timer(@default_timeout_ms, port, container_name)

  defp attach_timer(timeout_ms, port, container_name) when is_integer(timeout_ms) do
    Process.send_after(self(), {:litter_box_attach_timeout, port, container_name}, timeout_ms)
  end

  defp next_attach_event(%{started?: false} = state) do
    event =
      AttachEvents.event(state.session, :exec_started, %{
        runtime: state.request.runtime,
        mode: state.request.mode,
        argv: state.request.argv,
        cwd: state.request.cwd,
        network: state.request.network,
        effective_network: Map.get(state, :network_metadata),
        streaming_live?: true,
        container_name: state.container_name
      })

    {[event], %{state | started?: true}}
  end

  defp next_attach_event(%{port: port} = state) do
    receive do
      {^port, {:data, data}} ->
        event =
          AttachEvents.chunk_event(
            state.session,
            :stdout_chunk,
            cap(data, state.request.max_output_bytes)
          )

        {[event], state}

      {^port, {:exit_status, exit_status}} ->
        state = %{state | finished?: true}
        cancel_attach_timer(state.timer_ref)
        event = docker_attach_finished_event(state, exit_status, false)
        cleanup_attach_stream(state)
        {[event], :halt}

      {:litter_box_attach_timeout, ^port, container_name} ->
        System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)
        state = %{state | finished?: true}
        event = docker_attach_finished_event(state, nil, true)
        cleanup_attach_stream(state)
        {[event], :halt}
    end
  end

  defp next_attach_event(:halt), do: {:halt, :halt}

  defp docker_attach_finished_event(state, exit_status, timed_out?) do
    duration_ms = System.monotonic_time(:millisecond) - state.started_mono

    {files_changed, artifacts, diagnostics} =
      case snapshot_files(state.workspace_root) do
        {:ok, after_files} ->
          case workspace_delta(
                 state.workspace_root,
                 state.before_files,
                 after_files,
                 state.request.max_output_bytes
               ) do
            {:ok, files_changed, artifacts} -> {files_changed, artifacts, []}
            {:error, error} -> {[], [], [%{message: error.message, details: error.details}]}
          end

        {:error, error} ->
          {[], [], [%{message: error.message, details: error.details}]}
      end

    AttachEvents.event(state.session, :exec_finished, %{
      status: status(exit_status, timed_out?),
      exit_status: exit_status,
      duration_ms: duration_ms,
      files_changed: files_changed,
      artifacts: artifacts,
      diagnostics: diagnostics,
      resource_usage: %{},
      metadata: %{
        sandbox: state.request.sandbox,
        runtime: state.request.runtime,
        mode: state.request.mode,
        network: state.request.network,
        effective_network: Map.get(state, :network_metadata),
        image: image(state.session.instance),
        container_name: state.container_name,
        streaming_live?: true,
        timed_out?: timed_out?,
        security_boundary?: true
      }
    })
  end

  defp cleanup_attach_stream(:halt), do: :ok

  defp cleanup_attach_stream(%{finished?: finished?} = state) do
    cancel_attach_timer(state.timer_ref)

    unless finished? do
      cleanup_attach(state)
    end

    cleanup_egress_resources(Map.get(state, :egress_resources, []))
    if state.cleanup?, do: File.rm_rf(state.workspace_root)
    :ok
  end

  defp cleanup_attach(%{port: port, container_name: container_name} = state) do
    if is_port(port), do: Port.close(port)
    System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)
    cleanup_egress_resources(Map.get(state, :egress_resources, []))
    :ok
  rescue
    _exception -> :ok
  end

  defp cleanup_attach(metadata) when is_map(metadata) do
    cleanup_attach(%{
      port: Map.get(metadata, :port),
      container_name: Map.get(metadata, :container_name),
      egress_resources: Map.get(metadata, :egress_resources, [])
    })
  end

  defp cancel_attach_timer(nil), do: :ok
  defp cancel_attach_timer(ref), do: Process.cancel_timer(ref)

  defp invoke_docker(args, :infinity, _container_name) do
    case docker_cmd(args) do
      {:ok, output, exit_status} -> {:ok, output, exit_status, false}
      {:error, error} -> {:error, error}
    end
  end

  defp invoke_docker(args, timeout_ms, container_name) when is_integer(timeout_ms) do
    task = Task.async(fn -> docker_cmd(args) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, output, exit_status}} ->
        {:ok, output, exit_status, false}

      {:ok, {:error, error}} ->
        {:error, error}

      nil ->
        System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)
        {:ok, "", nil, true}
    end
  end

  defp invoke_docker_exec(args, :infinity) do
    case docker_cmd(args) do
      {:ok, output, exit_status} -> {:ok, output, exit_status, false}
      {:error, error} -> {:error, error}
    end
  end

  defp invoke_docker_exec(args, timeout_ms) when is_integer(timeout_ms) do
    task = Task.async(fn -> docker_cmd(args) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, output, exit_status}} -> {:ok, output, exit_status, false}
      {:ok, {:error, error}} -> {:error, error}
      nil -> {:ok, "", nil, true}
    end
  end

  defp docker_cmd(args) do
    case System.cmd("docker", args, stderr_to_stdout: true) do
      {output, exit_status} -> {:ok, output, exit_status}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp runtime_command(%ExecutionRequest{mode: :command, argv: argv}) when argv != [],
    do: {:ok, argv}

  defp runtime_command(%ExecutionRequest{mode: :command}) do
    {:error, Error.validation("docker command request requires argv", source: __MODULE__)}
  end

  defp runtime_command(%ExecutionRequest{mode: :script, runtime: runtime, source: source}) do
    case Map.fetch(@runtime_commands, runtime) do
      {:ok, command} ->
        {:ok, command ++ [source]}

      :error ->
        {:error,
         Error.validation("unsupported docker sandbox runtime",
           source: __MODULE__,
           details: %{runtime: runtime, supported_runtimes: Map.keys(@runtime_commands)}
         )}
    end
  end

  defp prepare_workspace(%Instance{} = instance, %ExecutionRequest{} = request) do
    case option(instance.metadata, :workspace_root) do
      workspace_root when is_binary(workspace_root) ->
        with :ok <- File.mkdir_p(workspace_root),
             :ok <- write_files(workspace_root, request.files),
             :ok <- ensure_workspace_user_writable(workspace_root) do
          {:ok, workspace_root, false}
        end

      _other ->
        prepare_one_shot_workspace(request)
    end
  end

  defp ensure_workspace_supported(%Instance{workspace: %{mode: mode}} = instance)
       when mode in [:copy_in, :stateful] do
    if is_binary(instance.workspace.mount) and instance.workspace.mount != "" do
      :ok
    else
      {:error,
       Error.validation("docker sandbox workspace mount must be configured",
         source: __MODULE__,
         details: %{workspace: instance.workspace}
       )}
    end
  end

  defp ensure_workspace_supported(%Instance{} = instance) do
    {:error,
     Error.validation("docker sandbox workspace mode is not supported yet",
       source: __MODULE__,
       details: %{
         mode: instance.workspace.mode,
         supported_modes: [:copy_in, :stateful],
         backend: instance.backend
       }
     )}
  end

  defp prepare_one_shot_workspace(%ExecutionRequest{} = request) do
    workspace_root =
      Path.join(host_tmp_dir(), "litter_box_#{System.unique_integer([:positive])}")

    case File.mkdir_p(workspace_root) do
      :ok ->
        case write_files(workspace_root, request.files) do
          :ok ->
            case ensure_workspace_user_writable(workspace_root) do
              :ok ->
                {:ok, workspace_root, true}

              {:error, error} ->
                File.rm_rf(workspace_root)
                {:error, error}
            end

          {:error, error} ->
            File.rm_rf(workspace_root)
            {:error, error}
        end

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to prepare docker sandbox workspace"
         )}
    end
  end

  defp write_files(_workspace_root, files) when files == %{}, do: :ok

  defp write_files(workspace_root, files) when is_map(files) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      with {:ok, path} <- safe_workspace_path(workspace_root, path),
           :ok <- ensure_no_symlink_path(workspace_root, path),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, to_string(content)) do
        {:cont, :ok}
      else
        {:error, %Error{} = error} ->
          {:halt, {:error, error}}

        {:error, reason} ->
          {:halt,
           {:error,
            Error.from_reason(reason,
              source: __MODULE__,
              message: "failed to prepare docker sandbox workspace"
            )}}
      end
    end)
  end

  defp safe_workspace_path(workspace_root, path) when is_binary(path) and path != "" do
    workspace_root = Path.expand(workspace_root)
    expanded = Path.expand(path, workspace_root)

    if expanded == workspace_root or String.starts_with?(expanded, workspace_root <> "/") do
      {:ok, expanded}
    else
      {:error, %{path: path, workspace_root: workspace_root}}
    end
  end

  defp safe_workspace_path(_workspace_root, path), do: {:error, %{path: path}}

  defp snapshot_files(workspace_root) do
    files =
      workspace_root
      |> walk_files()
      |> Enum.reduce(%{}, fn path, acc ->
        relative = Path.relative_to(path, workspace_root)
        :ok = ensure_no_symlink_path(workspace_root, path)
        :ok = ensure_regular_file(path)
        {:ok, stat} = File.lstat(path)
        {:ok, content} = File.read(path)

        Map.put(acc, relative, %{
          path: relative,
          bytes: stat.size,
          sha256: Base.encode16(:crypto.hash(:sha256, content), case: :lower)
        })
      end)

    {:ok, files}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp walk_files(root) do
    cond do
      regular_directory?(root) ->
        case File.ls(root) do
          {:ok, names} ->
            Enum.flat_map(names, fn name ->
              path = Path.join(root, name)

              cond do
                regular_directory?(path) -> walk_files(path)
                regular_file?(path) -> [path]
                true -> []
              end
            end)

          {:error, _reason} ->
            []
        end

      regular_file?(root) ->
        [root]

      true ->
        []
    end
  end

  defp workspace_delta(workspace_root, before_files, after_files, preview_limit) do
    paths = (Map.keys(before_files) ++ Map.keys(after_files)) |> Enum.uniq() |> Enum.sort()

    {files_changed, artifacts} =
      Enum.reduce(paths, {[], []}, fn path, {changes, artifacts} ->
        before_file = Map.get(before_files, path)
        after_file = Map.get(after_files, path)

        case change_kind(before_file, after_file) do
          nil ->
            {changes, artifacts}

          kind ->
            change = %{
              path: path,
              kind: kind,
              before_sha256: before_file && before_file.sha256,
              after_sha256: after_file && after_file.sha256,
              bytes: after_file && after_file.bytes
            }

            artifact =
              if after_file do
                artifact_for(workspace_root, path, after_file, preview_limit)
              end

            {[change | changes], maybe_prepend(artifacts, artifact)}
        end
      end)

    {:ok, Enum.reverse(files_changed), Enum.reverse(artifacts)}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp change_kind(nil, %{}), do: :created
  defp change_kind(%{}, nil), do: :deleted
  defp change_kind(%{sha256: sha}, %{sha256: sha}), do: nil
  defp change_kind(%{}, %{}), do: :modified

  defp artifact_for(workspace_root, path, file, preview_limit) do
    full_path = Path.join(workspace_root, path)
    :ok = ensure_no_symlink_path(workspace_root, full_path)
    :ok = ensure_regular_file(full_path)
    {:ok, content} = File.read(full_path)
    preview = cap(content, min(preview_limit, 4_096))

    %{
      ref: "sandbox://#{path}",
      path: path,
      bytes: file.bytes,
      sha256: file.sha256,
      preview: preview,
      truncated?: byte_size(content) > byte_size(preview)
    }
  end

  defp maybe_prepend(list, nil), do: list
  defp maybe_prepend(list, value), do: [value | list]

  defp docker_network_setup(%Instance{} = instance, %ExecutionRequest{} = request) do
    policy = option(instance.metadata, :policy) || %{}
    allowlist = Map.get(policy, :egress_allowlist, [])

    cond do
      request.network == :restricted and allowlist != [] ->
        setup_restricted_egress(instance, request, allowlist, policy)

      request.network == :disabled ->
        {:ok, %{args: ["--network", "none"], resources: [], metadata: %{mode: :disabled}}}

      request.network == :host ->
        {:ok, %{args: ["--network", "host"], resources: [], metadata: %{mode: :host}}}

      request.network == :restricted ->
        {:ok,
         %{
           args: ["--network", "none"],
           resources: [],
           metadata: %{mode: :restricted, deny_by_default?: true, egress_allowlist: []}
         }}
    end
  end

  defp docker_session_network_setup(%Instance{} = instance) do
    policy = option(instance.metadata, :policy) || %{}
    mode = Map.get(policy, :mode, :disabled)
    allowlist = Map.get(policy, :egress_allowlist, [])

    cond do
      mode == :restricted and allowlist != [] ->
        setup_restricted_egress(instance, nil, allowlist, policy)

      mode == :disabled ->
        {:ok, %{args: ["--network", "none"], resources: [], metadata: %{mode: :disabled}}}

      mode == :host ->
        {:ok, %{args: ["--network", "host"], resources: [], metadata: %{mode: :host}}}

      mode == :restricted ->
        {:ok,
         %{
           args: ["--network", "none"],
           resources: [],
           metadata: %{mode: :restricted, deny_by_default?: true, egress_allowlist: []}
         }}
    end
  end

  defp setup_restricted_egress(
         %Instance{} = instance,
         _request,
         allowlist,
         policy
       ) do
    with {:ok, entries} <- docker_restricted_egress_entries(allowlist),
         {:ok, allowlist_json} <- Jason.encode(entries) do
      id = System.unique_integer([:positive])
      network_name = "runic-sandbox-egress-#{id}"
      proxy_name = "runic-sandbox-egress-proxy-#{id}"
      proxy_image = egress_proxy_image(instance)

      resources = [
        %{kind: :container, id: proxy_name},
        %{kind: :network, id: network_name}
      ]

      with {:ok, _output, 0} <-
             docker_cmd(["network", "create", "--internal", network_name]),
           {:ok, _output, 0} <-
             docker_cmd(
               [
                 "run",
                 "-d",
                 "--rm",
                 "--pull",
                 "never",
                 "--name",
                 proxy_name,
                 "--add-host",
                 "runic-host.internal:host-gateway",
                 "-e",
                 "RUNIC_EGRESS_ALLOWLIST=#{allowlist_json}",
                 proxy_image,
                 "python3",
                 "-u",
                 "-c",
                 egress_proxy_script()
               ],
               resources
             ),
           {:ok, _output, 0} <-
             docker_cmd(
               [
                 "network",
                 "connect",
                 "--alias",
                 "host.docker.internal",
                 network_name,
                 proxy_name
               ],
               resources
             ) do
        {:ok,
         %{
           args: ["--network", network_name],
           resources: resources,
           metadata: %{
             mode: :restricted,
             deny_by_default?: Map.get(policy, :deny_by_default?, true),
             restricted_egress?: true,
             egress_allowlist: entries,
             proxy_container: proxy_name,
             network: network_name,
             proxy_image: proxy_image
           }
         }}
      end
    end
  end

  defp docker_cmd(args, cleanup_resources) do
    case docker_cmd(args) do
      {:ok, _output, 0} = ok ->
        ok

      {:ok, output, exit_status} ->
        cleanup_egress_resources(cleanup_resources)

        {:error,
         Error.validation("docker restricted egress setup failed",
           source: __MODULE__,
           details: %{args: redact_docker_args(args), exit_status: exit_status, output: output}
         )}

      {:error, error} ->
        cleanup_egress_resources(cleanup_resources)
        {:error, error}
    end
  end

  defp docker_restricted_egress_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case docker_restricted_egress_entry(entry) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, error} -> {:error, error}
    end
  end

  defp docker_restricted_egress_entry(%{host: "host.docker.internal", port: port} = entry)
       when is_integer(port) do
    scheme = Map.get(entry, :scheme)
    purpose = Map.get(entry, :purpose)

    cond do
      scheme not in ["http", "tcp"] ->
        unsupported_docker_egress_entry(entry, "scheme must be http or tcp")

      purpose not in [nil, "mcp", "model"] ->
        unsupported_docker_egress_entry(entry, "purpose must be mcp or model")

      true ->
        {:ok,
         %{scheme: scheme, host: "host.docker.internal", port: port, purpose: purpose || "mcp"}}
    end
  end

  defp docker_restricted_egress_entry(entry),
    do: unsupported_docker_egress_entry(entry, "host must be host.docker.internal")

  defp unsupported_docker_egress_entry(entry, reason) do
    {:error,
     Error.validation("docker restricted egress allow-list entry is not supported",
       source: __MODULE__,
       details: %{entry: entry, reason: reason}
     )}
  end

  defp effective_network_metadata(%Instance{} = instance, %ExecutionRequest{} = request) do
    policy = option(instance.metadata, :policy) || %{}

    %{
      mode: request.network,
      deny_by_default?: Map.get(policy, :deny_by_default?, request.network == :restricted),
      restricted_egress?:
        request.network == :restricted and Map.get(policy, :egress_allowlist, []) != [],
      egress_allowlist:
        if(request.network == :restricted, do: Map.get(policy, :egress_allowlist, []), else: []),
      mcp_boundary: Map.get(policy, :mcp_boundary)
    }
  end

  defp cleanup_egress_resources(resources) when is_list(resources) do
    Enum.each(resources, fn
      %{kind: :container, id: id} ->
        System.cmd("docker", ["rm", "-f", id], stderr_to_stdout: true)

      %{kind: :network, id: id} ->
        System.cmd("docker", ["network", "rm", id], stderr_to_stdout: true)

      _other ->
        :ok
    end)
  rescue
    _exception -> :ok
  end

  defp cleanup_egress_resources(_resources), do: :ok

  defp redact_docker_args(args) do
    Enum.map(args, fn
      "RUNIC_EGRESS_ALLOWLIST=" <> _json -> "RUNIC_EGRESS_ALLOWLIST=<redacted>"
      arg -> arg
    end)
  end

  defp egress_proxy_image(%Instance{} = instance) do
    backend_options = Map.get(instance.metadata, :backend_options, %{})
    option(backend_options, :egress_proxy_image) || image(instance)
  end

  defp egress_proxy_script do
    """
    import json, os, select, socket, threading

    entries = json.loads(os.environ.get("RUNIC_EGRESS_ALLOWLIST", "[]"))
    listeners = []

    def pump(left, right):
        sockets = [left, right]
        try:
            while True:
                readable, _, _ = select.select(sockets, [], [])
                for sock in readable:
                    data = sock.recv(65536)
                    if not data:
                        return
                    target = right if sock is left else left
                    target.sendall(data)
        finally:
            for sock in sockets:
                try:
                    sock.close()
                except Exception:
                    pass

    def serve(entry):
        listen_port = int(entry["port"])
        upstream_host = "runic-host.internal"
        upstream_port = listen_port
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("0.0.0.0", listen_port))
        server.listen(64)
        listeners.append(server)
        while True:
            client, _addr = server.accept()
            upstream = socket.create_connection((upstream_host, upstream_port), timeout=10)
            threading.Thread(target=pump, args=(client, upstream), daemon=True).start()

    for entry in entries:
        threading.Thread(target=serve, args=(entry,), daemon=True).start()

    threading.Event().wait()
    """
  end

  defp docker_attach_metadata(input) do
    Capabilities.attach_metadata(:live_stream,
      stdin_supported?: true,
      stdin_close_supported?: false,
      stderr_separate?: false,
      restricted_egress_supported?: true,
      mcp_boundary_supported?: true,
      process_host?: false,
      service_host?: false,
      mcp_boundary_transports: [:egress_allowlist],
      restricted_egress_hosts: ["host.docker.internal"],
      provider_transport: :docker_cli_port
    )
    |> Map.merge(
      Map.take(Map.new(input), [
        :state_tier,
        :process_host?,
        :workspace_persistent?,
        :service_host?,
        :snapshot_modes
      ])
    )
  end

  defp security_args(%Instance{metadata: metadata}) do
    backend_options = Map.get(metadata, :backend_options, %{})

    if option(backend_options, :disable_security_defaults?) do
      []
    else
      []
      |> maybe_security_arg("--security-opt", "no-new-privileges")
      |> maybe_cap_drop_all(option(backend_options, :cap_drop_all?))
    end
  end

  defp maybe_security_arg(args, flag, value), do: args ++ [flag, value]
  defp maybe_cap_drop_all(args, true), do: args ++ ["--cap-drop", "ALL"]
  defp maybe_cap_drop_all(args, _other), do: args

  defp resource_args(%Instance{metadata: metadata}) do
    backend_options = Map.get(metadata, :backend_options, %{})

    []
    |> maybe_resource_arg("--memory", option(backend_options, :memory))
    |> maybe_resource_arg("--cpus", option(backend_options, :cpus))
    |> maybe_resource_arg("--pids-limit", option(backend_options, :pids_limit))
  end

  defp maybe_resource_arg(args, _flag, nil), do: args
  defp maybe_resource_arg(args, flag, value), do: args ++ [flag, to_string(value)]

  defp env_args(%Instance{metadata: metadata}) do
    backend_options = Map.get(metadata, :backend_options, %{})

    (option(backend_options, :environment) || option(backend_options, :env) || %{})
    |> normalize_env()
    |> Enum.flat_map(fn {key, value} -> ["--env", "#{key}=#{value}"] end)
  end

  defp env_args(_other), do: []

  defp normalize_env(env) when is_map(env) do
    env
    |> Enum.flat_map(&normalize_env_pair/1)
    |> Map.new()
  end

  defp normalize_env(env) when is_list(env) do
    env
    |> Enum.flat_map(&normalize_env_pair/1)
    |> Map.new()
  end

  defp normalize_env(_env), do: %{}

  defp normalize_env_pair({key, nil}), do: normalize_env_name(key) |> Enum.map(&{&1, ""})

  defp normalize_env_pair({key, value}),
    do: normalize_env_name(key) |> Enum.map(&{&1, to_string(value)})

  defp normalize_env_pair(_pair), do: []

  defp normalize_env_name(key) when is_atom(key), do: normalize_env_name(Atom.to_string(key))

  defp normalize_env_name(key) when is_binary(key) do
    if key =~ ~r/^[A-Za-z_][A-Za-z0-9_]*$/ do
      [key]
    else
      []
    end
  end

  defp normalize_env_name(_key), do: []

  defp shell_escape(value) do
    value = to_string(value)

    if value =~ ~r|^[A-Za-z0-9_@%+=:,./-]+$| do
      value
    else
      "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
    end
  end

  defp status(_exit_status, true), do: :timeout
  defp status(0, false), do: :pass
  defp status(_exit_status, false), do: :fail

  defp docker_process_terminal_status(%{status: :pass}), do: :exited
  defp docker_process_terminal_status(%{status: "pass"}), do: :exited
  defp docker_process_terminal_status(%{status: :timeout}), do: :failed
  defp docker_process_terminal_status(%{status: "timeout"}), do: :failed
  defp docker_process_terminal_status(_payload), do: :failed

  defp docker_process_status(%Session{} = session, line) do
    [pid | rest] = String.split(line, ~r/\s+/, trim: true)
    command = Enum.at(rest, 1) || Enum.at(rest, 0) || "process"

    ProcessStatus.new!(
      id: pid,
      session_id: session.id,
      backend: session.backend,
      status: :running,
      pid: parse_pid(pid),
      metadata: %{command: command}
    )
  end

  defp parse_pid(pid) do
    case Integer.parse(pid) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp diagnostics(output, max_output_bytes, timed_out?) do
    []
    |> maybe_timeout_diagnostic(timed_out?)
    |> maybe_truncation_diagnostic(output, max_output_bytes)
  end

  defp maybe_timeout_diagnostic(diagnostics, false), do: diagnostics

  defp maybe_timeout_diagnostic(diagnostics, true) do
    [%{message: "container sandbox execution timed out", details: %{}} | diagnostics]
  end

  defp maybe_truncation_diagnostic(diagnostics, output, max_output_bytes) do
    if byte_size(output) > max_output_bytes do
      [
        %{message: "sandbox output truncated", details: %{output_bytes: byte_size(output)}}
        | diagnostics
      ]
    else
      diagnostics
    end
  end

  defp split_output(output), do: {output, ""}

  defp cap(output, max_output_bytes) when byte_size(output) <= max_output_bytes, do: output
  defp cap(output, max_output_bytes), do: binary_part(output, 0, max_output_bytes)

  defp ensure_container_available(%Instance{} = instance) do
    cond do
      not container_available?(instance) ->
        {:error,
         Error.validation(
           "#{instance.backend} container runtime is not available for sandbox execution",
           source: __MODULE__,
           details: %{
             backend: instance.backend,
             docker_available?: docker_available?(),
             runsc_available?: runsc_available?(),
             docker_runsc_runtime_available?: docker_runsc_runtime_available?(),
             container_runtime: option(instance.metadata, :container_runtime)
           }
         )}

      not image_available?(image(instance)) ->
        {:error,
         Error.validation(
           "#{instance.backend} sandbox image is not available locally",
           source: __MODULE__,
           details: %{backend: instance.backend, image: image(instance), pull_policy: :never}
         )}

      true ->
        :ok
    end
  end

  defp container_available?(%Profile{backend: :gvisor}),
    do: docker_available?() and docker_runsc_runtime_available?()

  defp container_available?(%Profile{}), do: docker_available?()

  defp container_available?(%Instance{backend: :gvisor}),
    do: docker_available?() and docker_runsc_runtime_available?()

  defp container_available?(%Instance{}), do: docker_available?()
  defp container_available?(_other), do: docker_available?()

  defp ensure_no_symlink_tree(root) do
    root
    |> walk_entries()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.lstat(path) do
        {:ok, %{type: :symlink}} ->
          {:halt,
           {:error,
            Error.validation("sandbox filesystem path may not be a symlink",
              source: __MODULE__,
              details: %{path: path}
            )}}

        {:ok, _stat} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, Error.from_reason(reason, source: __MODULE__)}}
      end
    end)
  end

  defp ensure_no_symlink_path(workspace_root, full_path) do
    workspace_root = Path.expand(workspace_root)
    full_path = Path.expand(full_path)
    relative = Path.relative_to(full_path, workspace_root)

    if relative == "." do
      ensure_not_symlink(workspace_root)
    else
      relative
      |> Path.split()
      |> Enum.reduce_while(workspace_root, fn component, current ->
        next = Path.join(current, component)

        case File.lstat(next) do
          {:ok, %{type: :symlink}} ->
            {:halt,
             {:error,
              Error.validation("sandbox filesystem path may not be a symlink",
                source: __MODULE__,
                details: %{path: Path.relative_to(next, workspace_root)}
              )}}

          {:ok, _stat} ->
            {:cont, next}

          {:error, :enoent} ->
            {:halt, :ok}

          {:error, reason} ->
            {:halt, {:error, Error.from_reason(reason, source: __MODULE__)}}
        end
      end)
      |> case do
        :ok -> :ok
        path when is_binary(path) -> :ok
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp ensure_not_symlink(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        {:error,
         Error.validation("sandbox filesystem path may not be a symlink",
           source: __MODULE__,
           details: %{path: path}
         )}

      {:ok, _stat} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp ensure_regular_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        :ok

      {:ok, stat} ->
        {:error,
         Error.validation("sandbox filesystem path is not a regular file",
           source: __MODULE__,
           details: %{path: path, type: stat.type}
         )}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp regular_file?(path), do: match?({:ok, %{type: :regular}}, File.lstat(path))
  defp regular_directory?(path), do: match?({:ok, %{type: :directory}}, File.lstat(path))

  defp walk_entries(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} ->
        children =
          case File.ls(root) do
            {:ok, names} -> Enum.map(names, &Path.join(root, &1))
            {:error, _reason} -> []
          end

        [root | Enum.flat_map(children, &walk_entries/1)]

      {:ok, _stat} ->
        [root]

      {:error, _reason} ->
        []
    end
  end

  defp exec_ready?(profile_or_instance),
    do: container_available?(profile_or_instance) and image_available?(image(profile_or_instance))

  defp docker_available? do
    case System.find_executable("docker") do
      nil ->
        false

      _path ->
        case System.cmd("docker", ["info", "--format", "{{.ServerVersion}}"],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> true
          _other -> false
        end
    end
  rescue
    _exception -> false
  end

  defp runsc_available? do
    !!System.find_executable("runsc") or docker_runsc_runtime_available?()
  rescue
    _exception -> false
  end

  defp docker_runsc_runtime_available?, do: docker_runtime_available?("runsc")

  defp docker_runtime_available?(runtime) do
    case System.find_executable("docker") do
      nil ->
        false

      docker ->
        runtime_available_from_docker_info?(docker, runtime)
    end
  end

  defp runtime_available_from_docker_info?(docker, runtime) do
    case System.cmd(docker, ["info", "--format", "{{json .Runtimes}}"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> runtime_available_from_json?(runtime)

      _other ->
        false
    end
  rescue
    _exception -> false
  end

  defp runtime_available_from_json?(json, runtime) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, runtimes} when is_map(runtimes) -> Map.has_key?(runtimes, runtime)
      _other -> String.contains?(json, runtime)
    end
  end

  defp image_available?(image) do
    case System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true) do
      {_output, 0} -> true
      _other -> false
    end
  rescue
    _exception -> false
  end

  defp image(%Profile{} = profile), do: option(profile.backend_options, :image) || @default_image
  defp image(%Instance{} = instance), do: option(instance.metadata, :image) || @default_image
  defp image(_other), do: @default_image

  defp runtime_args(%Instance{backend: :gvisor}), do: ["--runtime", "runsc"]
  defp runtime_args(%Instance{}), do: []

  defp container_runtime(%Profile{backend: :gvisor}), do: "runsc"
  defp container_runtime(%Profile{}), do: nil
  defp container_runtime(_other), do: nil

  defp isolation_level(:gvisor), do: :gvisor
  defp isolation_level(_backend), do: :container

  defp docker_missing_requirements(backend, docker_available?, runsc_available?, image_available?) do
    []
    |> maybe_missing(not docker_available?, :docker, "Docker CLI/daemon is unavailable")
    |> maybe_missing(
      backend == :gvisor and not runsc_available?,
      :runsc,
      "Docker runsc runtime is unavailable"
    )
    |> maybe_missing(
      not image_available?,
      :image,
      "Configured sandbox image is not available locally"
    )
    |> Enum.reverse()
  end

  defp maybe_missing(requirements, true, requirement, message),
    do: [%{requirement: requirement, message: message} | requirements]

  defp maybe_missing(requirements, false, _requirement, _message), do: requirements

  defp health_diagnostics(:gvisor, docker_available?, runsc_available?, image_available?, image) do
    []
    |> maybe_health_diagnostic(docker_available?, "docker daemon is unavailable")
    |> maybe_health_diagnostic(runsc_available?, "Docker runsc runtime is unavailable")
    |> maybe_health_diagnostic(image_available?, "Docker image #{image} is unavailable locally")
    |> Enum.reverse()
  end

  defp health_diagnostics(_backend, docker_available?, _runsc_available?, image_available?, image) do
    []
    |> maybe_health_diagnostic(docker_available?, "docker daemon is unavailable")
    |> maybe_health_diagnostic(image_available?, "Docker image #{image} is unavailable locally")
    |> Enum.reverse()
  end

  defp maybe_health_diagnostic(diagnostics, true, _message), do: diagnostics

  defp maybe_health_diagnostic(diagnostics, false, message),
    do: [%{message: message} | diagnostics]

  defp option(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp option(_map, _key), do: nil

  defp option(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp option(_map, _key, default), do: default

  # Host directory under which runic creates managed temp paths (stateful
  # workspaces, checkpoints) that are bind-mounted into containers. Defaults to
  # `System.tmp_dir!()`. Overridable via `config :litter_box, host_tmp_dir: "/path"`
  # for Docker engines that do not share the OS temp dir into their VM — e.g.
  # Colima/Lima with default mounts, where `/var/folders` (macOS) and `/tmp` are
  # not visible to dockerd, producing bind-mount "source path does not exist"
  # failures even though the directory exists on the host. Point this at a shared
  # path (e.g. a dir under `$HOME`) in those environments.
  defp host_tmp_dir do
    Application.get_env(:litter_box, :host_tmp_dir) || System.tmp_dir!()
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp stateful?(%Profile{} = profile), do: profile.stateful? or profile.workspace.persist?

  defp stateful_instance?(%Instance{} = instance),
    do: not is_nil(option(instance.metadata, :workspace_root))

  defp maybe_put_stateful_workspace(metadata, %Profile{} = profile) do
    if stateful?(profile) do
      Map.put(
        metadata,
        :workspace_root,
        Path.join(
          host_tmp_dir(),
          "litter_box_stateful_#{profile.name}_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"
        )
      )
    else
      metadata
    end
  end
end
