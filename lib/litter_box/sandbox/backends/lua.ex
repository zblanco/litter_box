defmodule LitterBox.Backends.Lua do
  @moduledoc """
  In-process Lua backend backed by the optional `:lua` package.

  This backend is intended for small deterministic transform snippets. It runs
  in a separate BEAM task with a timeout, but it is not a hard security
  boundary and should not be used for untrusted package-manager or OS work.
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
  def provision(%Profile{backend: :lua} = profile, opts) do
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
     Error.validation("lua backend cannot provision profile backend #{inspect(profile.backend)}",
       source: __MODULE__,
       details: %{backend: profile.backend}
     )}
  end

  @impl true
  def exec(%Instance{} = instance, %ExecutionRequest{} = request, _opts) do
    started_mono = System.monotonic_time(:millisecond)

    with :ok <- ensure_available(),
         :ok <- ensure_runtime(request) do
      task = Task.async(fn -> eval(script(request)) end)

      case Task.yield(task, request.timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, values}} ->
          duration_ms = System.monotonic_time(:millisecond) - started_mono

          ExecutionResult.new(
            status: :pass,
            stdout: values |> format_values() |> cap(request.max_output_bytes),
            stderr: "",
            exit_status: 0,
            duration_ms: duration_ms,
            files_changed: [],
            artifacts: [],
            backend: instance.backend,
            isolation_level: instance.isolation_level,
            diagnostics: diagnostics(values, request.max_output_bytes),
            resource_usage: %{},
            metadata: metadata(request)
          )

        {:ok, {:error, message}} ->
          duration_ms = System.monotonic_time(:millisecond) - started_mono

          ExecutionResult.new(
            status: :fail,
            stdout: "",
            stderr: cap(message, request.max_output_bytes),
            exit_status: 1,
            duration_ms: duration_ms,
            files_changed: [],
            artifacts: [],
            backend: instance.backend,
            isolation_level: instance.isolation_level,
            diagnostics: [%{message: "lua execution failed", details: %{error: message}}],
            resource_usage: %{},
            metadata: metadata(request)
          )

        nil ->
          duration_ms = System.monotonic_time(:millisecond) - started_mono

          ExecutionResult.new(
            status: :timeout,
            stdout: "",
            stderr: "lua execution timed out",
            exit_status: nil,
            duration_ms: duration_ms,
            files_changed: [],
            artifacts: [],
            backend: instance.backend,
            isolation_level: instance.isolation_level,
            diagnostics: [
              %{message: "lua execution timed out", details: %{timeout_ms: request.timeout_ms}}
            ],
            resource_usage: %{},
            metadata: metadata(request)
          )
      end
    end
  end

  @impl true
  def upload(%Instance{}, _files, _opts) do
    {:error,
     Error.validation("lua backend does not support persistent upload", source: __MODULE__)}
  end

  @impl true
  def download(%Instance{}, _paths, _opts) do
    {:error,
     Error.validation("lua backend does not support persistent download", source: __MODULE__)}
  end

  @impl true
  def snapshot(%Instance{} = instance, _opts) do
    {:ok, %{instance_id: instance.id, backend: :lua, stateful?: false}}
  end

  @impl true
  def reset(%Instance{}, _opts), do: :ok

  @impl true
  def destroy(%Instance{}, _opts), do: :ok

  @impl true
  def health(_opts) do
    {:ok,
     %{
       name: :lua,
       available?: available?(),
       runtimes: [:lua],
       isolation_level: :in_process,
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
  def open_session(%Profile{backend: :lua} = profile, opts) do
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
       Error.validation("lua backend is not available; add the optional :lua dependency",
         source: __MODULE__,
         details: %{backend: :lua}
       )}
    end
  end

  defp available?, do: Code.ensure_loaded?(Lua)

  defp ensure_runtime(%ExecutionRequest{runtime: :lua}), do: :ok

  defp ensure_runtime(%ExecutionRequest{} = request) do
    {:error,
     Error.validation("lua backend only supports the lua runtime",
       source: __MODULE__,
       details: %{runtime: request.runtime, supported_runtimes: [:lua]}
     )}
  end

  defp eval(source) do
    try do
      {values, _state} = apply(Lua, :eval!, [source, []])
      {:ok, List.wrap(values)}
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      kind, reason -> {:error, Exception.format_banner(kind, reason)}
    end
  end

  defp script(%ExecutionRequest{mode: :script, source: source}), do: source
  defp script(%ExecutionRequest{mode: :command, argv: argv}), do: Enum.join(argv, " ")

  defp format_values([]), do: ""

  defp format_values(values) do
    values
    |> Enum.map(&inspect/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp cap(output, max_output_bytes) when byte_size(output) <= max_output_bytes, do: output
  defp cap(output, max_output_bytes), do: binary_part(output, 0, max_output_bytes)

  defp diagnostics(values, max_output_bytes) do
    output = format_values(values)

    if byte_size(output) > max_output_bytes do
      [%{message: "sandbox output truncated", details: %{output_bytes: byte_size(output)}}]
    else
      []
    end
  end

  defp metadata(%ExecutionRequest{} = request) do
    %{
      sandbox: request.sandbox,
      runtime: request.runtime,
      mode: request.mode,
      network: request.network,
      stateful?: false,
      security_boundary?: false,
      input_files: Map.keys(request.files)
    }
  end

  defp terminal_attach_stdin_error do
    {:error,
     Error.validation("terminal attach result does not accept stdin after execution",
       source: __MODULE__
     )}
  end
end
