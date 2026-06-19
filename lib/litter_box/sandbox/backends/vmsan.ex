defmodule LitterBox.Backends.Vmsan do
  @moduledoc """
  vmsan-backed local Firecracker microVM sandbox backend.

  vmsan owns the low-level Firecracker, jailer, network, agent, and image
  lifecycle. This adapter keeps LitterBox's provider-neutral session and
  execution contracts around that CLI surface.
  """

  @behaviour LitterBox.Backend

  alias LitterBox.AttachEvents
  alias LitterBox.AttachHandle
  alias LitterBox.Capabilities
  alias LitterBox.Checkpoint
  alias LitterBox.Error
  alias LitterBox.ExecutionRequest
  alias LitterBox.ExecutionResult
  alias LitterBox.FileRef
  alias LitterBox.HostProbe
  alias LitterBox.Instance
  alias LitterBox.ProcessHandle
  alias LitterBox.ProcessStatus
  alias LitterBox.Profile
  alias LitterBox.Session
  alias LitterBox.VmsanCLI

  @transfer_root_name "litter_box_vmsan_files"

  @impl true
  def provision(%Profile{backend: :vmsan} = profile, opts) do
    health = doctor(opts)

    metadata = %{
      security_boundary?: true,
      backend_module: __MODULE__,
      executable: health.executable,
      available?: health.available?,
      host_available?: health.available?,
      configured?: health.available?,
      exec_ready?: health.available?,
      stateful?: true,
      doctor: redact_doctor(health),
      backend_options: profile.backend_options
    }

    {:ok,
     Instance.from_profile(profile,
       id: Keyword.get(opts, :id),
       state: if(health.available?, do: :ready, else: :unavailable),
       metadata: metadata
     )}
  end

  def provision(%Profile{} = profile, _opts) do
    {:error,
     Error.validation(
       "vmsan backend cannot provision profile backend #{inspect(profile.backend)}",
       source: __MODULE__,
       details: %{backend: profile.backend}
     )}
  end

  @impl true
  def exec(%Instance{} = instance, %ExecutionRequest{} = request, opts) do
    with {:ok, profile} <- one_shot_profile(instance, request),
         {:ok, session} <- open_session(profile, opts) do
      exec_one_shot_session(session, request, opts)
    end
  end

  @impl true
  def upload(%Instance{}, _files, _opts),
    do: {:error, Error.validation("vmsan upload requires an open session", source: __MODULE__)}

  @impl true
  def download(%Instance{}, _paths, _opts),
    do: {:error, Error.validation("vmsan download requires an open session", source: __MODULE__)}

  @impl true
  def snapshot(%Instance{} = instance, _opts) do
    {:ok,
     %{
       instance_id: instance.id,
       backend: :vmsan,
       stateful?: true,
       microvm?: true
     }}
  end

  @impl true
  def reset(%Instance{}, _opts), do: :ok

  @impl true
  def destroy(%Instance{} = instance, opts), do: remove_vm(instance.id, opts)

  @impl true
  def health(opts) do
    doctor = doctor(opts)
    available? = doctor.available?

    {:ok,
     %{
       name: :vmsan,
       available?: available?,
       host_available?: available?,
       configured?: available?,
       exec_ready?: available?,
       executable: doctor.executable,
       version: vmsan_version(opts),
       runtimes: [:bash, :sh, :python, :node, :elixir, :lua],
       isolation_level: :microvm,
       transport_model: :local_microvm,
       state_model: :checkpointable,
       network: %{default: :disabled, provider_managed?: true},
       stateful?: true,
       security_boundary?: true,
       capabilities: Capabilities.to_map(session_capabilities()),
       missing_requirements: doctor.missing_requirements,
       diagnostics: doctor.diagnostics,
       doctor: redact_doctor(doctor)
     }}
  end

  @impl true
  def open_session(%Profile{backend: :vmsan} = profile, opts) do
    with {:ok, transfer_root} <- create_transfer_root() do
      case open_session_with_transfer_root(profile, opts, transfer_root) do
        {:ok, session} ->
          {:ok, session}

        {:error, _error} = result ->
          cleanup_transfer_root(transfer_root)
          result
      end
    end
  end

  @impl true
  def close_session(%Session{} = session, opts) do
    remove_result = remove_vm(session.id, session_opts(session, opts))
    cleanup_transfer_root(session)
    remove_result
  end

  @impl true
  def exec_session(%Session{} = session, %ExecutionRequest{} = request, opts) do
    started = System.monotonic_time(:millisecond)

    with :ok <- ensure_available(opts),
         :ok <- ensure_supported_request(request),
         :ok <- write_request_files(session, request, request.files, opts),
         {:ok, argv} <- request_argv(request),
         {:ok, result} <-
           VmsanCLI.exec_args(session.id, argv, workdir: request.cwd, env: request_env(request))
           |> run_vmsan(session_cli_opts(session, request_opts(request, opts))) do
      duration_ms = System.monotonic_time(:millisecond) - started
      stdout = cap(result.stream_output, request.max_output_bytes)

      ExecutionResult.new(
        status: if(result.exit_status == 0, do: :pass, else: :fail),
        stdout: stdout,
        stderr: "",
        exit_status: result.exit_status,
        duration_ms: duration_ms,
        files_changed: [],
        artifacts: [],
        backend: :vmsan,
        isolation_level: :microvm,
        diagnostics: diagnostics(result.stream_output, request.max_output_bytes),
        resource_usage: %{},
        metadata: %{
          sandbox: request.sandbox,
          runtime: request.runtime,
          mode: request.mode,
          network: request.network,
          vm_id: session.id,
          session_id: session.id,
          security_boundary?: true
        }
      )
    end
  end

  @impl true
  def attach_session(%Session{} = session, %ExecutionRequest{} = request, opts) do
    with {:ok, result} <- exec_session(session, request, opts) do
      AttachEvents.terminal_handle(session, request, result,
        metadata: %{provider_transport: :vmsan_cli}
      )
    end
  end

  @impl true
  def write_stdin(%AttachHandle{}, _input, _opts), do: terminal_attach_stdin_error()

  @impl true
  def close_attach(%AttachHandle{}, _opts), do: :ok

  @impl true
  def start_process(%Session{} = session, %ExecutionRequest{} = request, opts) do
    started_mono = System.monotonic_time(:millisecond)

    with :ok <- ensure_available(opts),
         {:ok, argv} <- request_argv(request),
         {:ok, handle} <- open_session_process(session, request, argv, started_mono, opts) do
      {:ok, handle}
    end
  end

  @impl true
  def list_processes(%Session{} = session, opts) do
    with {:ok, output} <- vmsan_ps(session.id, nil, session_cli_opts(session, opts)) do
      statuses =
        output
        |> String.split("\n", trim: true)
        |> Enum.reduce([], fn line, acc ->
          case vmsan_process_status(session, line) do
            {:ok, status} -> [status | acc]
            {:error, _error} -> acc
          end
        end)
        |> Enum.reverse()

      {:ok, statuses}
    end
  end

  @impl true
  def process_status(%Session{} = session, %ProcessHandle{} = handle, opts) do
    pidfile = Map.get(handle.metadata, :pidfile)

    with {:ok, pid} <- vmsan_process_pid(session.id, pidfile, session_cli_opts(session, opts)),
         {:ok, output} <- vmsan_ps(session.id, pid, session_cli_opts(session, opts)) do
      case output |> String.split("\n", trim: true) |> List.first() do
        nil ->
          ProcessStatus.from_handle(handle, status: :unknown, pid: parse_pid(pid))

        line ->
          {:ok, status} = vmsan_process_status(session, line)

          ProcessStatus.from_handle(handle,
            status: status.status,
            pid: status.pid,
            metadata: Map.merge(handle.metadata, status.metadata)
          )
      end
    else
      {:error, _error} ->
        ProcessStatus.from_handle(handle)
    end
  end

  def process_status(%Session{} = session, process_id, _opts) when is_binary(process_id) do
    ProcessStatus.new(
      id: process_id,
      session_id: session.id,
      backend: session.backend,
      status: :unknown,
      metadata: %{provider_transport: :vmsan_cli}
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
         Error.validation("vmsan process handle is not writable",
           source: __MODULE__,
           details: %{backend: :vmsan}
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  @impl true
  def close_process_stdin(%ProcessHandle{metadata: metadata}, _opts) do
    case Map.get(metadata, :port) do
      port when is_port(port) ->
        Port.command(port, <<4>>)
        :ok

      _other ->
        {:error,
         Error.validation("vmsan process handle is not writable",
           source: __MODULE__,
           details: %{backend: :vmsan}
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  @impl true
  def signal_process(%ProcessHandle{metadata: metadata}, signal, opts) do
    vm_id = Map.get(metadata, :vm_id)
    pidfile = Map.get(metadata, :pidfile)

    with vm_id when is_binary(vm_id) <- vm_id,
         {:ok, pid} <- vmsan_process_pid(vm_id, pidfile, handle_cli_opts(metadata, opts)),
         {:ok, _output} <-
           vmsan_process_shell(
             vm_id,
             "kill -s #{shell_escape(to_string(signal))} #{shell_escape(pid)}",
             handle_cli_opts(metadata, opts)
           ) do
      :ok
    else
      _other ->
        {:error,
         Error.validation("vmsan process handle does not expose a signal target",
           source: __MODULE__,
           details: %{backend: :vmsan}
         )}
    end
  end

  @impl true
  def kill_process(%ProcessHandle{} = handle, opts) do
    case signal_process(handle, "TERM", opts) do
      :ok -> cleanup_process_handle(handle.metadata)
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
          status: Map.get(payload, :status, :exited),
          exit_status: Map.get(payload, :exit_status)
        )

      nil ->
        ProcessStatus.from_handle(handle)
    end
  end

  @impl true
  def write_file(%Session{} = session, path, contents, opts) do
    with {:ok, tmp_root} <- tmp_root(session),
         {:ok, local_path} <- safe_tmp_path(tmp_root, local_transfer_path(path)),
         :ok <- File.mkdir_p(Path.dirname(local_path)),
         :ok <- File.write(local_path, contents),
         {:ok, _result} <-
           VmsanCLI.upload_args(session.id, [local_path], dest: Path.dirname(remote_path(path)))
           |> run_vmsan(session_cli_opts(session, opts)),
         {:ok, stat} <- File.stat(local_path) do
      FileRef.new(
        path: path,
        kind: :file,
        bytes: stat.size,
        sha256: Base.encode16(:crypto.hash(:sha256, IO.iodata_to_binary(contents)), case: :lower)
      )
    end
  end

  @impl true
  def read_file(%Session{} = session, path, opts) do
    with {:ok, tmp_root} <- tmp_root(session),
         {:ok, local_path} <- safe_tmp_path(tmp_root, local_transfer_path(path)),
         :ok <- File.mkdir_p(Path.dirname(local_path)),
         {:ok, _result} <-
           VmsanCLI.download_args(session.id, remote_path(path), dest: local_path)
           |> run_vmsan(session_cli_opts(session, opts)),
         :ok <- ensure_regular_file(local_path) do
      File.read(local_path)
    end
  end

  @impl true
  def list_files(%Session{}, _path, _opts),
    do:
      {:error,
       Error.validation("vmsan list_files is not supported by the CLI adapter yet",
         source: __MODULE__
       )}

  @impl true
  def delete_file(%Session{} = session, path, opts) do
    request =
      ExecutionRequest.new!(
        sandbox: session.sandbox,
        runtime: :bash,
        source: "rm -rf -- #{shell_escape(remote_path(path))}"
      )

    case exec_session(session, request, opts) do
      {:ok, %{status: :pass}} ->
        :ok

      {:ok, result} ->
        {:error,
         Error.validation("vmsan delete_file failed",
           source: __MODULE__,
           details: %{result: result}
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def checkpoint(%Session{} = session, _spec, opts) do
    with {:ok, result} <-
           VmsanCLI.snapshot_create_args(session.id) |> run_vmsan(session_opts(session, opts)) do
      event = result.event

      checkpoint_id =
        Map.get(event, "snapshotId") || "snapshot_#{System.unique_integer([:positive])}"

      Checkpoint.new(
        id: checkpoint_id,
        session_id: session.id,
        backend: :vmsan,
        ref: "vmsan://#{session.id}/snapshots/#{checkpoint_id}",
        created_at: DateTime.utc_now(),
        metadata: %{
          kind: :microvm_snapshot,
          preserves: Checkpoint.preserves(:microvm_snapshot),
          caveats: [
            "Vmsan microVM snapshots preserve VM filesystem and memory state; external network connections should be treated as broken after restore."
          ],
          snapshot_path: Map.get(event, "snapshotPath"),
          mem_path: Map.get(event, "memPath")
        }
      )
    end
  end

  @impl true
  def restore(%Session{} = session, %Checkpoint{} = checkpoint, opts) do
    with :ok <- validate_checkpoint(session, checkpoint),
         {:ok, profile} <-
           Profile.new(
             name: session.sandbox,
             backend: :vmsan,
             runtimes: restore_runtimes(session),
             network: session.policy.network,
             backend_options:
               session_backend_options(session)
               |> Map.put(:snapshot, checkpoint.id)
           ),
         {:ok, restored} <- open_session(profile, opts) do
      close_session(session, opts)
      {:ok, restored}
    end
  end

  def restore(%Session{}, _checkpoint, _opts),
    do:
      {:error, Error.validation("vmsan restore requires a vmsan checkpoint", source: __MODULE__)}

  defp open_session_process(
         %Session{} = session,
         %ExecutionRequest{} = request,
         argv,
         started_mono,
         opts
       ) do
    process_id = "process-#{System.unique_integer([:positive])}"
    pidfile = "/tmp/runic-sandbox-#{process_id}.pid"

    command =
      [
        "sh",
        "-lc",
        "printf '%s' \"$$\" > \"$1\"; shift; exec \"$@\"",
        "runic-process",
        pidfile
      ] ++ argv

    args =
      VmsanCLI.exec_interactive_args(session.id, command,
        workdir: request.cwd,
        env: request_env(request)
      )

    with {:ok, port} <- open_vmsan_process_port(args, session_cli_opts(session, opts)) do
      if request.stdin not in [nil, ""], do: Port.command(port, request.stdin)

      events =
        Stream.resource(
          fn ->
            %{
              session: session,
              request: request,
              port: port,
              process_id: process_id,
              pidfile: pidfile,
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
        command: argv,
        events: events,
        metadata: %{
          streaming_live?: true,
          provider_transport: :vmsan_cli,
          port: port,
          vm_id: session.id,
          executable: session_executable(session),
          process_id: process_id,
          pidfile: pidfile
        }
      )
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
        vm_id: state.session.id
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
        event = vmsan_process_finished_event(state, exit_status)
        cleanup_process_stream(state)
        {[event], :halt}
    end
  end

  defp next_process_event(:halt), do: {:halt, :halt}

  defp vmsan_process_finished_event(state, exit_status) do
    duration_ms = System.monotonic_time(:millisecond) - state.started_mono

    AttachEvents.event(state.session, :process_finished, %{
      process_id: state.process_id,
      status: if(exit_status == 0, do: :exited, else: :failed),
      exit_status: exit_status,
      duration_ms: duration_ms,
      vm_id: state.session.id
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

  defp open_vmsan_process_port(args, opts) do
    port_open = Keyword.get(opts, :port_open, &open_vmsan_port/2)
    port_open.(args, opts)
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp open_vmsan_port(args, opts) do
    {command, argv} =
      VmsanCLI.command(args,
        executable: executable(opts),
        sudo?: false,
        json?: false
      )

    case System.find_executable(command) do
      nil ->
        {:error,
         Error.validation("vmsan executable is not available",
           source: __MODULE__,
           details: %{command: command}
         )}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            args: argv
          ])

        {:ok, port}
    end
  end

  defp vmsan_process_pid(_vm_id, pidfile, _opts) when pidfile in [nil, ""],
    do:
      {:error,
       Error.validation("vmsan process handle does not expose a pidfile", source: __MODULE__)}

  defp vmsan_process_pid(vm_id, pidfile, opts) do
    with {:ok, output} <- vmsan_process_shell(vm_id, "cat #{shell_escape(pidfile)}", opts),
         pid when pid != "" <- String.trim(output) do
      {:ok, pid}
    else
      _other ->
        {:error,
         Error.validation("vmsan process pid lookup failed",
           source: __MODULE__,
           details: %{vm_id: vm_id, pidfile: pidfile}
         )}
    end
  end

  defp vmsan_ps(vm_id, nil, opts),
    do: vmsan_process_shell(vm_id, "ps -eo pid=,stat=,comm= 2>/dev/null || true", opts)

  defp vmsan_ps(vm_id, pid, opts),
    do:
      vmsan_process_shell(
        vm_id,
        "ps -p #{shell_escape(pid)} -o pid=,stat=,comm= 2>/dev/null || true",
        opts
      )

  defp vmsan_process_shell(vm_id, source, opts) do
    VmsanCLI.exec_args(vm_id, ["sh", "-lc", source])
    |> run_vmsan(opts)
    |> case do
      {:ok, result} -> {:ok, result.stream_output}
      {:error, error} -> {:error, error}
    end
  end

  defp vmsan_process_status(%Session{} = session, line) do
    case Regex.run(~r/^\s*(\d+)\s+(\S+)\s+(.+?)\s*$/, line) do
      [_line, pid, stat, command] ->
        ProcessStatus.new(
          id: "pid-#{pid}",
          session_id: session.id,
          backend: session.backend,
          status: process_status_from_stat(stat),
          pid: parse_pid(pid),
          metadata: %{
            provider_transport: :vmsan_cli,
            vm_id: session.id,
            stat: stat,
            command: command
          }
        )

      _other ->
        ProcessStatus.new(
          id: "unknown-#{System.unique_integer([:positive])}",
          session_id: session.id,
          backend: session.backend,
          status: :unknown,
          metadata: %{provider_transport: :vmsan_cli, raw: line}
        )
    end
  end

  defp process_status_from_stat("Z" <> _rest), do: :exited
  defp process_status_from_stat("T" <> _rest), do: :running
  defp process_status_from_stat(_stat), do: :running

  defp parse_pid(pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {value, ""} -> value
      _other -> nil
    end
  end

  defp parse_pid(_pid), do: nil

  defp handle_cli_opts(metadata, opts) do
    opts
    |> Keyword.put_new(:executable, Map.get(metadata, :executable, "vmsan"))
    |> Keyword.put_new(:sudo?, false)
  end

  defp create_vm(%Profile{} = profile, opts) do
    backend_options = profile.backend_options

    create_opts =
      backend_options
      |> Map.take([
        :vcpus,
        :memory,
        :kernel,
        :rootfs,
        :runtime,
        :project,
        :disk,
        :timeout,
        :bandwidth,
        :snapshot
      ])
      |> Map.put(:network_policy, network_policy(profile.policy.network))

    with {:ok, result} <-
           create_opts
           |> VmsanCLI.create_args()
           |> run_vmsan(
             opts
             |> Keyword.put(:sudo?, sudo?(profile))
             |> Keyword.put_new(:executable, profile_executable(profile, opts))
           ) do
      event = result.event

      case Map.get(event, "vmId") do
        vm_id when is_binary(vm_id) and vm_id != "" ->
          {:ok, %{vm_id: vm_id, event: event}}

        _other ->
          {:error,
           Error.validation("vmsan create did not return a vmId",
             source: __MODULE__,
             details: %{event: event}
           )}
      end
    end
  end

  defp exec_one_shot_session(%Session{} = session, %ExecutionRequest{} = request, opts) do
    result = exec_session(session, request, opts)

    case {result, close_session(session, opts)} do
      {{:ok, execution_result}, :ok} ->
        {:ok, execution_result}

      {{:ok, execution_result}, {:error, cleanup_error}} ->
        {:error,
         Error.validation("vmsan one-shot cleanup failed",
           source: __MODULE__,
           details: %{execution_result: execution_result, cleanup_error: cleanup_error}
         )}

      {{:error, execution_error}, _cleanup_result} ->
        {:error, execution_error}
    end
  end

  defp open_session_with_transfer_root(%Profile{} = profile, opts, transfer_root) do
    with :ok <- ensure_available(opts),
         {:ok, vm} <- create_vm(profile, opts) do
      result =
        with :ok <- prepare_workspace(profile, opts, vm.vm_id) do
          session_from_vm(profile, opts, transfer_root, vm)
        end

      case result do
        {:ok, session} ->
          {:ok, session}

        {:error, _error} = result ->
          remove_vm(
            vm.vm_id,
            opts
            |> Keyword.put(:sudo?, sudo?(profile))
            |> Keyword.put_new(:executable, profile_executable(profile, opts))
          )

          result
      end
    end
  end

  defp prepare_workspace(%Profile{} = profile, opts, vm_id) do
    workspace_path = Map.get(profile.backend_options, :workspace_path, "/workspace")
    escaped = shell_escape(workspace_path)

    VmsanCLI.exec_args(
      vm_id,
      ["sh", "-lc", "mkdir -p -- #{escaped} && chown ubuntu:ubuntu -- #{escaped}"],
      sudo?: true
    )
    |> run_vmsan(
      opts
      |> Keyword.put_new(:executable, profile_executable(profile, opts))
      |> Keyword.put_new(:sudo?, false)
    )
    |> case do
      {:ok, _result} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp session_from_vm(%Profile{} = profile, opts, transfer_root, vm) do
    with {:ok, instance} <-
           provision(%{profile | stateful?: true}, Keyword.put(opts, :id, vm.vm_id)) do
      Session.from_instance(instance,
        id: vm.vm_id,
        capabilities: session_capabilities(),
        policy: profile.policy,
        state_model: :checkpointable,
        transport_model: :local_microvm,
        persistent_identity?: true,
        workspace_ref: "vmsan://#{vm.vm_id}",
        metadata: %{
          vm_id: vm.vm_id,
          event: vm.event,
          executable: profile_executable(profile, opts),
          sudo?: sudo?(profile),
          transfer_root: transfer_root
        }
      )
    end
  end

  defp remove_vm(vm_id, opts) do
    case VmsanCLI.remove_args(vm_id) |> run_vmsan(opts) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp run_vmsan(args, opts) do
    VmsanCLI.run_json(args,
      executable: executable(opts),
      sudo?: Keyword.get(opts, :sudo?, false),
      runner: Keyword.get(opts, :runner, &System.cmd/3),
      timeout_ms: Keyword.get(opts, :timeout_ms, 60_000)
    )
  end

  defp ensure_available(opts) do
    case doctor(opts) do
      %{available?: true} ->
        :ok

      doctor ->
        {:error,
         Error.validation("vmsan sandbox provider is not available for execution",
           source: __MODULE__,
           details: %{
             missing_requirements: doctor.missing_requirements,
             diagnostics: doctor.diagnostics
           }
         )}
    end
  end

  defp doctor(opts),
    do: HostProbe.vmsan_doctor(commands: Keyword.get(opts, :commands, &System.cmd/3))

  defp redact_doctor(doctor), do: Map.drop(doctor, [:raw_output])

  defp vmsan_version(opts) do
    commands = Keyword.get(opts, :commands, &System.cmd/3)

    case System.find_executable(executable(opts)) do
      nil ->
        nil

      path ->
        case commands.(path, ["--version"], stderr_to_stdout: true) do
          {output, _status} -> String.trim(output)
          _other -> nil
        end
    end
  rescue
    _exception -> nil
  end

  defp request_argv(%ExecutionRequest{mode: :command, argv: argv}) when argv != [],
    do: {:ok, argv}

  defp request_argv(%ExecutionRequest{mode: :command}) do
    {:error, Error.validation("vmsan command request requires argv", source: __MODULE__)}
  end

  defp request_argv(%ExecutionRequest{mode: :script, runtime: runtime, source: source}) do
    case runtime do
      runtime when runtime in [:bash, :sh] ->
        {:ok, ["sh", "-lc", source]}

      :python ->
        {:ok, ["python3", "-c", source]}

      :node ->
        {:ok, ["node", "-e", source]}

      :elixir ->
        {:ok, ["elixir", "-e", source]}

      :lua ->
        {:ok, ["lua", "-e", source]}

      _other ->
        {:error,
         Error.validation("unsupported vmsan sandbox runtime",
           source: __MODULE__,
           details: %{runtime: runtime}
         )}
    end
  end

  defp session_capabilities do
    Capabilities.new!(
      exec?: true,
      files?: false,
      inline_files?: false,
      artifacts?: false,
      session_files?: true,
      checkpoints?: true,
      services?: false,
      proxy?: false,
      leases?: false,
      streaming?: true,
      network_policy?: true,
      persistent_identity?: true,
      metadata:
        Capabilities.attach_metadata(:terminal_adapter,
          provider_transport: :vmsan_cli,
          restricted_egress_supported?: false,
          state_tier: :persistent_process_host,
          process_host?: true,
          workspace_persistent?: true,
          live_process_stream?: true,
          service_host?: false,
          snapshot_modes: [:microvm_snapshot]
        )
    )
  end

  defp terminal_attach_stdin_error do
    {:error,
     Error.validation("terminal attach result does not accept stdin after execution",
       source: __MODULE__
     )}
  end

  defp request_policy(%ExecutionRequest{} = request) do
    LitterBox.Policy.new!(
      network: request.network,
      timeout_ms: request.timeout_ms,
      max_output_bytes: request.max_output_bytes,
      allowed_runtimes: [request.runtime],
      isolation_minimum: :microvm,
      persist_changes?: true
    )
  end

  defp validate_checkpoint(%Session{} = session, %Checkpoint{} = checkpoint) do
    cond do
      checkpoint.session_id != session.id ->
        {:error,
         Error.validation("checkpoint belongs to a different sandbox session", source: __MODULE__)}

      checkpoint.backend != :vmsan ->
        {:error,
         Error.validation("checkpoint belongs to a different sandbox backend", source: __MODULE__)}

      checkpoint.metadata[:kind] != :microvm_snapshot ->
        {:error,
         Error.validation("vmsan restore only supports microVM checkpoints", source: __MODULE__)}

      true ->
        :ok
    end
  end

  defp restore_runtimes(%Session{policy: %{allowed_runtimes: [_ | _] = runtimes}}), do: runtimes
  defp restore_runtimes(%Session{}), do: [:bash]

  defp tmp_root(%Session{} = session) do
    case Map.get(session.metadata, :transfer_root) || Map.get(session.metadata, "transfer_root") do
      path when is_binary(path) and path != "" ->
        with :ok <- ensure_transfer_root(path) do
          {:ok, path}
        end

      _other ->
        create_transfer_root()
    end
  end

  defp safe_tmp_path(root, path) do
    root = Path.expand(root)
    path = Path.expand(path, root)

    cond do
      path == root ->
        {:error, Error.validation("vmsan file path must name a file", source: __MODULE__)}

      not String.starts_with?(path, root <> "/") ->
        {:error,
         Error.validation("vmsan file path escapes managed temp root", source: __MODULE__)}

      true ->
        with :ok <- ensure_no_symlink_path(root, path) do
          {:ok, path}
        end
    end
  end

  defp remote_path(path), do: "/" <> (path |> to_string() |> String.trim_leading("/"))
  defp network_policy(:disabled), do: "deny-all"
  defp network_policy(:restricted), do: "deny-all"
  defp network_policy(:host), do: "allow-all"

  defp sudo?(%Profile{} = profile), do: Map.get(profile.backend_options, :sudo?, false)
  defp executable(opts), do: Keyword.get(opts, :executable, "vmsan")

  defp profile_executable(%Profile{} = profile, opts),
    do: Map.get(profile.backend_options, :executable, executable(opts))

  defp one_shot_profile(%Instance{} = instance, %ExecutionRequest{} = request) do
    Profile.new(
      name: instance.name,
      backend: :vmsan,
      runtimes: [request.runtime],
      network: request.network,
      stateful?: true,
      policy: request_policy(request),
      backend_options: Map.get(instance.metadata, :backend_options, %{}),
      metadata: Map.take(instance.metadata, [:executable])
    )
  end

  defp ensure_supported_request(%ExecutionRequest{stdin: stdin}) when stdin not in [nil, ""] do
    {:error,
     Error.validation("vmsan exec does not support stdin yet",
       source: __MODULE__,
       details: %{field: :stdin}
     )}
  end

  defp ensure_supported_request(%ExecutionRequest{}), do: :ok

  defp request_opts(%ExecutionRequest{} = request, opts) do
    Keyword.put(opts, :timeout_ms, request.timeout_ms)
  end

  defp write_request_files(_session, _request, files, _opts) when files in [%{}, nil], do: :ok

  defp write_request_files(%Session{} = session, %ExecutionRequest{} = request, files, opts)
       when is_map(files) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      with {:ok, guest_path} <- request_file_path(request.cwd, path),
           {:ok, _file_ref} <- write_file(session, guest_path, to_string(content), opts) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp request_env(%ExecutionRequest{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :env, Map.get(metadata, "env", %{})) do
      env when is_map(env) or is_list(env) -> env
      _other -> %{}
    end
  end

  defp session_opts(%Session{} = session, opts) do
    opts
    |> Keyword.put_new(:executable, session_executable(session))
    |> Keyword.put_new(:sudo?, session_sudo?(session))
  end

  defp session_cli_opts(%Session{} = session, opts) do
    opts
    |> Keyword.put_new(:executable, session_executable(session))
    |> Keyword.put_new(:sudo?, false)
  end

  defp session_executable(%Session{} = session),
    do: Map.get(session.metadata, :executable, Map.get(session.metadata, "executable", "vmsan"))

  defp session_sudo?(%Session{} = session),
    do: Map.get(session.metadata, :sudo?, Map.get(session.metadata, "sudo?", false))

  defp session_backend_options(%Session{} = session) do
    %{}
    |> Map.put(:sudo?, session_sudo?(session))
    |> Map.put(:executable, session_executable(session))
  end

  defp create_transfer_root do
    root =
      Path.join([
        System.tmp_dir!(),
        @transfer_root_name,
        "#{System.unique_integer([:positive])}-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      ])

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- ensure_transfer_root(root) do
      {:ok, root}
    else
      {:error, reason} when is_atom(reason) ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to create vmsan transfer root"
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp request_file_path(cwd, path) do
    path = to_string(path)
    cwd = Path.expand(cwd || "/workspace")

    cond do
      path == "" ->
        {:error, Error.validation("vmsan inline file path must be non-empty", source: __MODULE__)}

      String.starts_with?(path, "/") ->
        {:error,
         Error.validation("vmsan inline file path must be relative to the request cwd",
           source: __MODULE__,
           details: %{path: path, cwd: cwd}
         )}

      true ->
        guest_path = Path.expand(path, cwd)

        if guest_path != cwd and String.starts_with?(guest_path, cwd <> "/") do
          {:ok, guest_path}
        else
          {:error,
           Error.validation("vmsan inline file path escapes the request cwd",
             source: __MODULE__,
             details: %{path: path, cwd: cwd}
           )}
        end
    end
  end

  defp local_transfer_path(path) do
    path
    |> to_string()
    |> String.trim_leading("/")
  end

  defp ensure_transfer_root(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory, access: access}} when access in [:read_write, :write] ->
        :ok

      {:ok, %{type: :directory}} ->
        :ok

      {:ok, stat} ->
        {:error,
         Error.validation("vmsan transfer root is not a directory",
           source: __MODULE__,
           details: %{path: path, type: stat.type}
         )}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp cleanup_transfer_root(%Session{} = session) do
    case Map.get(session.metadata, :transfer_root, Map.get(session.metadata, "transfer_root")) do
      path when is_binary(path) and path != "" ->
        cleanup_transfer_root(path)

      _other ->
        :ok
    end

    :ok
  end

  defp cleanup_transfer_root(path) when is_binary(path) do
    root = Path.join(System.tmp_dir!(), @transfer_root_name) |> Path.expand()
    expanded = Path.expand(path)

    if String.starts_with?(expanded, root <> "/") do
      File.rm_rf(expanded)
    end

    :ok
  end

  defp ensure_no_symlink_path(root, full_path) do
    root = Path.expand(root)
    full_path = Path.expand(full_path)
    relative = Path.relative_to(full_path, root)

    relative
    |> Path.split()
    |> Enum.reduce_while(root, fn component, current ->
      next = Path.join(current, component)

      case File.lstat(next) do
        {:ok, %{type: :symlink}} ->
          {:halt,
           {:error,
            Error.validation("vmsan transfer path may not be a symlink",
              source: __MODULE__,
              details: %{path: Path.relative_to(next, root)}
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

  defp ensure_regular_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        :ok

      {:ok, stat} ->
        {:error,
         Error.validation("vmsan transfer path is not a regular file",
           source: __MODULE__,
           details: %{path: path, type: stat.type}
         )}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp cap(output, max) when byte_size(output) <= max, do: output
  defp cap(output, max), do: binary_part(output, 0, max)

  defp diagnostics(output, max) do
    if byte_size(output) > max do
      [%{message: "sandbox output truncated", details: %{output_bytes: byte_size(output)}}]
    else
      []
    end
  end

  defp shell_escape(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
end
