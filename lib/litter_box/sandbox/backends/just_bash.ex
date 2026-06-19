defmodule LitterBox.Backends.JustBash do
  @moduledoc """
  In-process virtual shell backend backed by the optional `:just_bash` package.

  This backend is useful for tests, examples, and low-latency deterministic
  shell-like snippets. It is not a hard security boundary.
  """

  @behaviour LitterBox.Backend

  alias LitterBox.AttachEvents
  alias LitterBox.AttachHandle
  alias LitterBox.Capabilities
  alias LitterBox.Error
  alias LitterBox.ExecutionRequest
  alias LitterBox.ExecutionResult
  alias LitterBox.Instance
  alias LitterBox.Profile
  alias LitterBox.Session

  @impl true
  def provision(%Profile{backend: :just_bash} = profile, opts) do
    {:ok,
     Instance.from_profile(profile,
       id: Keyword.get(opts, :id),
       state: if(available?(), do: :ready, else: :unavailable),
       metadata: %{
         security_boundary?: false,
         backend_module: __MODULE__,
         available?: available?()
       }
     )}
  end

  def provision(%Profile{} = profile, _opts) do
    {:error,
     Error.validation(
       "just_bash backend cannot provision profile backend #{inspect(profile.backend)}",
       source: __MODULE__,
       details: %{backend: profile.backend}
     )}
  end

  @impl true
  def exec(%Instance{} = instance, %ExecutionRequest{} = request, _opts) do
    started_mono = System.monotonic_time(:millisecond)

    with :ok <- ensure_available(),
         :ok <- ensure_runtime(request) do
      bash_opts = [
        files: request.files,
        env: %{},
        cwd: request.cwd,
        network: %{enabled: request.network != :disabled}
      ]

      bash = apply(JustBash, :new, [bash_opts])
      {raw_result, _bash} = apply(JustBash, :exec, [bash, script(request)])

      stdout = Map.get(raw_result, :stdout, Map.get(raw_result, "stdout", ""))
      stderr = Map.get(raw_result, :stderr, Map.get(raw_result, "stderr", ""))
      exit_status = Map.get(raw_result, :exit_code, Map.get(raw_result, "exit_code", 0))
      duration_ms = System.monotonic_time(:millisecond) - started_mono

      ExecutionResult.new(
        status: if(exit_status == 0, do: :pass, else: :fail),
        stdout: cap(stdout, request.max_output_bytes),
        stderr: cap(stderr, request.max_output_bytes),
        exit_status: exit_status,
        duration_ms: duration_ms,
        files_changed: [],
        artifacts: [],
        backend: instance.backend,
        isolation_level: instance.isolation_level,
        diagnostics: diagnostics(stdout, stderr, request.max_output_bytes),
        resource_usage: %{},
        metadata: %{
          sandbox: request.sandbox,
          runtime: request.runtime,
          mode: request.mode,
          network: request.network,
          stateful?: false,
          security_boundary?: false
        }
      )
    end
  end

  @impl true
  def upload(%Instance{}, _files, _opts) do
    {:error,
     Error.validation("just_bash backend does not support persistent upload",
       source: __MODULE__
     )}
  end

  @impl true
  def download(%Instance{}, _paths, _opts) do
    {:error,
     Error.validation("just_bash backend does not support persistent download",
       source: __MODULE__
     )}
  end

  @impl true
  def snapshot(%Instance{} = instance, _opts) do
    {:ok, %{instance_id: instance.id, backend: :just_bash, stateful?: false}}
  end

  @impl true
  def reset(%Instance{}, _opts), do: :ok

  @impl true
  def destroy(%Instance{}, _opts), do: :ok

  @impl true
  def health(_opts) do
    {:ok,
     %{
       name: :just_bash,
       available?: available?(),
       runtimes: [:bash],
       isolation_level: :in_process_virtual,
       network: %{enabled: false},
       stateful?: false,
       security_boundary?: false,
       capabilities:
         Capabilities.to_map(
           Capabilities.one_shot_exec(
             network_policy?: false,
             persistent_identity?: false,
             streaming?: true,
             metadata: one_shot_attach_metadata()
           )
         )
     }}
  end

  @impl true
  def open_session(%Profile{backend: :just_bash} = profile, opts) do
    with {:ok, instance} <- provision(profile, opts) do
      Session.from_instance(instance,
        capabilities:
          Capabilities.one_shot_exec(
            network_policy?: false,
            persistent_identity?: false,
            streaming?: true,
            metadata: one_shot_attach_metadata()
          ),
        policy: profile.policy,
        state_model: :one_shot,
        transport_model: :in_process,
        persistent_identity?: false
      )
    end
  end

  defp one_shot_attach_metadata do
    Capabilities.attach_metadata(:terminal_adapter,
      state_tier: :one_shot_exec,
      process_host?: false,
      workspace_persistent?: false,
      live_process_stream?: false,
      service_host?: false,
      snapshot_modes: []
    )
  end

  @impl true
  def attach_session(
        %Session{instance: %Instance{} = instance} = session,
        %ExecutionRequest{} = request,
        opts
      ) do
    with {:ok, result} <- exec(instance, request, opts) do
      AttachEvents.terminal_handle(session, request, result)
    end
  end

  @impl true
  def write_stdin(%AttachHandle{}, _input, _opts), do: terminal_attach_stdin_error()

  @impl true
  def close_attach(%AttachHandle{}, _opts), do: :ok

  defp ensure_available do
    if available?() do
      :ok
    else
      {:error,
       Error.validation("just_bash is not available; add the optional :just_bash dependency",
         source: __MODULE__,
         details: %{backend: :just_bash}
       )}
    end
  end

  defp available?, do: Code.ensure_loaded?(JustBash)

  defp ensure_runtime(%ExecutionRequest{runtime: :bash}), do: :ok

  defp ensure_runtime(%ExecutionRequest{} = request) do
    {:error,
     Error.validation("just_bash backend only supports the bash runtime",
       source: __MODULE__,
       details: %{runtime: request.runtime, supported_runtimes: [:bash]}
     )}
  end

  defp script(%ExecutionRequest{mode: :script, source: source}), do: source
  defp script(%ExecutionRequest{mode: :command, argv: argv}), do: Enum.join(argv, " ")

  defp cap(output, max_output_bytes) when byte_size(output) <= max_output_bytes, do: output
  defp cap(output, max_output_bytes), do: binary_part(output, 0, max_output_bytes)

  defp diagnostics(stdout, stderr, max_output_bytes) do
    output_bytes = byte_size(stdout) + byte_size(stderr)

    if output_bytes > max_output_bytes do
      [%{message: "sandbox output truncated", details: %{output_bytes: output_bytes}}]
    else
      []
    end
  end

  defp terminal_attach_stdin_error do
    {:error,
     Error.validation("terminal attach result does not accept stdin after execution",
       source: __MODULE__
     )}
  end
end
