defmodule LitterBox.Backends.Remote do
  @moduledoc """
  Optional remote microVM backend.

  The first provider shape targets existing Fly Machines through the `fly` or
  `flyctl` CLI. Health is deliberately local and configuration-only so the
  Workbench can report readiness without making remote calls or exposing
  credentials.
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

  @default_provider :fly_machines
  @default_token_env "FLY_API_TOKEN"
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
  def provision(%Profile{backend: :remote} = profile, opts) do
    health = health_for(profile)

    {:ok,
     Instance.from_profile(profile,
       id: Keyword.get(opts, :id),
       state: if(health.available?, do: :ready, else: :unavailable),
       metadata: %{
         security_boundary?: true,
         backend_module: __MODULE__,
         available?: health.available?,
         provider: provider(profile),
         provider_runtime: provider_runtime(profile),
         credential_policy: credential_policy(profile),
         diagnostics: health.diagnostics
       }
     )}
  end

  def provision(%Profile{} = profile, _opts) do
    {:error,
     Error.validation(
       "remote backend cannot provision profile backend #{inspect(profile.backend)}",
       source: __MODULE__,
       details: %{backend: profile.backend}
     )}
  end

  @impl true
  def exec(%Instance{} = instance, %ExecutionRequest{} = request, _opts) do
    started_mono = System.monotonic_time(:millisecond)

    with :ok <- ensure_remote_available(instance),
         :ok <- ensure_files_supported(request),
         {:ok, command} <- runtime_command(request),
         {:ok, output, exit_status, timed_out?} <- run_remote(instance, request, command) do
      duration_ms = System.monotonic_time(:millisecond) - started_mono
      {stdout, stderr, normalized_exit_status} = normalize_output(output, exit_status)

      ExecutionResult.new(
        status: status(normalized_exit_status, timed_out?),
        stdout: cap(stdout, request.max_output_bytes),
        stderr: cap(stderr, request.max_output_bytes),
        exit_status: normalized_exit_status,
        duration_ms: duration_ms,
        files_changed: [],
        artifacts: [],
        backend: instance.backend,
        isolation_level: instance.isolation_level,
        diagnostics: diagnostics(stdout <> stderr, request.max_output_bytes, timed_out?),
        resource_usage: %{},
        metadata: %{
          sandbox: request.sandbox,
          runtime: request.runtime,
          mode: request.mode,
          network: request.network,
          provider: option(instance.metadata, :provider),
          command_transport: :fly_machine_exec,
          stateful?: true,
          security_boundary?: true
        }
      )
    end
  end

  @impl true
  def upload(%Instance{}, _files, _opts) do
    {:error,
     Error.validation("remote backend persistent upload is not supported",
       source: __MODULE__,
       details: %{backend: :remote}
     )}
  end

  @impl true
  def download(%Instance{}, _paths, _opts) do
    {:error,
     Error.validation("remote backend persistent download is not supported",
       source: __MODULE__,
       details: %{backend: :remote}
     )}
  end

  @impl true
  def snapshot(%Instance{} = instance, _opts) do
    {:ok,
     %{
       instance_id: instance.id,
       backend: :remote,
       provider: option(instance.metadata, :provider),
       credential_policy: option(instance.metadata, :credential_policy),
       stateful?: true
     }}
  end

  @impl true
  def reset(%Instance{}, _opts), do: :ok

  @impl true
  def destroy(%Instance{}, _opts), do: :ok

  @impl true
  def health(opts) do
    profile = Keyword.get(opts, :profile, Profile.new!(backend: :remote))
    {:ok, health_for(profile)}
  end

  defp health_for(%Profile{} = profile) do
    provider = provider(profile)
    executable = fly_executable(profile)
    fly_cli_available? = is_binary(executable)
    configured? = configured?(profile)
    credential_policy = credential_policy(profile)
    auth_configured? = auth_configured?(profile)
    auth_required? = credential_policy == :env_token

    auth_ready? =
      case credential_policy do
        :env_token -> auth_configured?
        :ambient_cli_allowed -> true
        :none -> false
      end

    available? = provider == :fly_machines and fly_cli_available? and configured? and auth_ready?

    %{
      name: :remote,
      available?: available?,
      host_available?: fly_cli_available?,
      configured?: configured?,
      exec_ready?: available?,
      provider: provider,
      fly_cli_available?: fly_cli_available?,
      executable: executable,
      credential_policy: credential_policy,
      auth_required?: auth_required?,
      auth_configured?: auth_configured?,
      runtimes: [:bash, :sh, :python, :node, :elixir, :lua],
      isolation_level: :remote_microvm,
      network: %{default: :restricted, provider_managed?: true},
      stateful?: true,
      security_boundary?: true,
      capabilities:
        Capabilities.to_map(
          Capabilities.new!(
            exec?: true,
            files?: false,
            inline_files?: false,
            artifacts?: false,
            session_files?: false,
            checkpoints?: false,
            services?: false,
            proxy?: false,
            leases?: false,
            streaming?: true,
            network_policy?: true,
            persistent_identity?: true,
            metadata: remote_attach_metadata()
          )
        ),
      missing_requirements:
        remote_missing_requirements(provider, fly_cli_available?, configured?, auth_ready?),
      diagnostics: health_diagnostics(provider, fly_cli_available?, configured?, auth_ready?)
    }
  end

  @impl true
  def open_session(%Profile{backend: :remote} = profile, opts) do
    with {:ok, instance} <- provision(profile, opts) do
      Session.from_instance(instance,
        capabilities: session_capabilities(),
        policy: profile.policy,
        state_model: :persistent_workspace,
        transport_model: :provider_cli,
        persistent_identity?: true,
        workspace_ref: "remote://#{instance.id}"
      )
    end
  end

  @impl true
  def exec_session(
        %Session{instance: %Instance{} = instance},
        %ExecutionRequest{} = request,
        opts
      ) do
    exec(instance, request, opts)
  end

  @impl true
  def attach_session(%Session{} = session, %ExecutionRequest{} = request, opts) do
    with {:ok, result} <- exec_session(session, request, opts) do
      AttachEvents.terminal_handle(session, request, result,
        metadata: %{provider_transport: :fly_machine_exec}
      )
    end
  end

  @impl true
  def write_stdin(%AttachHandle{}, _input, _opts), do: terminal_attach_stdin_error()

  @impl true
  def close_attach(%AttachHandle{}, _opts), do: :ok

  defp ensure_remote_available(%Instance{} = instance) do
    cond do
      option(instance.metadata, :provider) != :fly_machines ->
        {:error,
         Error.validation("unsupported remote sandbox provider",
           source: __MODULE__,
           details: %{provider: option(instance.metadata, :provider)}
         )}

      option(instance.metadata, :available?) ->
        :ok

      true ->
        {:error,
         Error.validation("remote sandbox provider is not available for execution",
           source: __MODULE__,
           details: %{
             backend: :remote,
             provider: option(instance.metadata, :provider),
             diagnostics: option(instance.metadata, :diagnostics) || []
           }
         )}
    end
  end

  defp ensure_files_supported(%ExecutionRequest{files: files}) when files == %{}, do: :ok

  defp ensure_files_supported(%ExecutionRequest{} = request) do
    {:error,
     Error.validation("remote sandbox execution does not support inline files yet",
       source: __MODULE__,
       details: %{file_count: map_size(request.files), backend: :remote}
     )}
  end

  defp runtime_command(%ExecutionRequest{mode: :command, argv: argv}) when argv != [],
    do: {:ok, argv}

  defp runtime_command(%ExecutionRequest{mode: :command}) do
    {:error, Error.validation("remote command request requires argv", source: __MODULE__)}
  end

  defp runtime_command(%ExecutionRequest{mode: :script, runtime: runtime, source: source}) do
    case Map.fetch(@runtime_commands, runtime) do
      {:ok, command} ->
        {:ok, command ++ [source]}

      :error ->
        {:error,
         Error.validation("unsupported remote sandbox runtime",
           source: __MODULE__,
           details: %{runtime: runtime, supported_runtimes: Map.keys(@runtime_commands)}
         )}
    end
  end

  defp run_remote(%Instance{} = instance, %ExecutionRequest{} = request, command) do
    provider_config = option(instance.metadata, :provider_runtime) || %{}
    executable = provider_config.executable

    args =
      [
        "machine",
        "exec",
        "--app",
        provider_config.app,
        "--json",
        "--timeout",
        timeout_seconds(request.timeout_ms),
        provider_config.machine_id,
        fly_command(command)
      ]

    invoke_fly(executable, args, provider_config, request.timeout_ms || @default_timeout_ms)
  end

  defp session_capabilities do
    Capabilities.new!(
      exec?: true,
      files?: false,
      inline_files?: false,
      artifacts?: false,
      session_files?: false,
      checkpoints?: false,
      services?: false,
      proxy?: false,
      leases?: false,
      streaming?: true,
      network_policy?: true,
      persistent_identity?: true,
      metadata: remote_attach_metadata()
    )
  end

  defp remote_attach_metadata do
    Capabilities.attach_metadata(:terminal_adapter,
      provider_transport: :fly_machine_exec,
      restricted_egress_supported?: false,
      state_tier: :persistent_workspace,
      process_host?: false,
      workspace_persistent?: true,
      live_process_stream?: false,
      service_host?: false,
      snapshot_modes: [],
      provider_api_capabilities: %{
        exec?: true,
        ps?: true,
        signal?: true,
        suspend?: true,
        live_process_contract?: false,
        reason: :fly_machines_api_client_not_implemented
      }
    )
  end

  defp fly_command(command), do: command |> Enum.map(&shell_escape/1) |> Enum.join(" ")

  defp shell_escape(value) do
    value = to_string(value)

    if value =~ ~r|^[A-Za-z0-9_@%+=:,./-]+$| do
      value
    else
      "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
    end
  end

  defp terminal_attach_stdin_error do
    {:error,
     Error.validation("terminal attach result does not accept stdin after execution",
       source: __MODULE__
     )}
  end

  defp invoke_fly(executable, args, provider_config, :infinity) do
    fly_cmd(executable, args, provider_config)
  end

  defp invoke_fly(executable, args, provider_config, timeout_ms) when is_integer(timeout_ms) do
    task = Task.async(fn -> fly_cmd(executable, args, provider_config) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, output, exit_status, timed_out?}} -> {:ok, output, exit_status, timed_out?}
      {:ok, {:error, error}} -> {:error, error}
      nil -> {:ok, "", nil, true}
    end
  end

  defp fly_cmd(executable, args, provider_config) do
    with {:ok, env} <- fly_env(provider_config) do
      case System.cmd(executable, args, stderr_to_stdout: true, env: env) do
        {output, exit_status} -> {:ok, output, exit_status, false}
      end
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp fly_env(%{credential_policy: :env_token, token_env: token_env}) do
    case System.get_env(token_env) do
      token when is_binary(token) and token != "" ->
        {:ok, [{"FLY_API_TOKEN", token}]}

      _other ->
        {:error,
         Error.validation("remote sandbox token env is required for execution",
           source: __MODULE__,
           details: %{token_env: token_env, credential_policy: :env_token}
         )}
    end
  end

  defp fly_env(%{credential_policy: :ambient_cli_allowed}), do: {:ok, []}

  defp fly_env(%{credential_policy: :none}) do
    {:error,
     Error.validation("remote sandbox credential policy forbids execution",
       source: __MODULE__,
       details: %{credential_policy: :none}
     )}
  end

  defp normalize_output(output, exit_status) do
    with {:ok, data} <- Jason.decode(output),
         true <- is_map(data) do
      stdout = get(data, :stdout, output) || ""
      stderr = get(data, :stderr, "") || ""
      normalized_exit_status = get(data, :exit_status, get(data, :exit_code, exit_status))
      {to_string(stdout), to_string(stderr), normalized_exit_status}
    else
      _other -> {output, "", exit_status}
    end
  end

  defp timeout_seconds(:infinity), do: "0"

  defp timeout_seconds(timeout_ms) when is_integer(timeout_ms),
    do: Integer.to_string(div(timeout_ms, 1_000))

  defp timeout_seconds(_timeout_ms), do: Integer.to_string(div(@default_timeout_ms, 1_000))

  defp status(_exit_status, true), do: :timeout
  defp status(0, false), do: :pass
  defp status(_exit_status, false), do: :fail

  defp cap(output, max_output_bytes) when byte_size(output) <= max_output_bytes, do: output
  defp cap(output, max_output_bytes), do: binary_part(output, 0, max_output_bytes)

  defp diagnostics(output, max_output_bytes, timed_out?) do
    []
    |> maybe_timeout_diagnostic(timed_out?)
    |> maybe_truncation_diagnostic(output, max_output_bytes)
  end

  defp maybe_timeout_diagnostic(diagnostics, false), do: diagnostics

  defp maybe_timeout_diagnostic(diagnostics, true) do
    [%{message: "remote sandbox execution timed out", details: %{}} | diagnostics]
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

  defp remote_missing_requirements(provider, fly_cli_available?, configured?, auth_ready?) do
    []
    |> maybe_missing(provider != :fly_machines, :provider, "Unsupported remote sandbox provider")
    |> maybe_missing(not fly_cli_available?, :fly_cli, "fly or flyctl executable is unavailable")
    |> maybe_missing(not configured?, :provider_config, "Fly app and machine_id are required")
    |> maybe_missing(not auth_ready?, :auth, "Remote provider credentials are required")
    |> Enum.reverse()
  end

  defp maybe_missing(requirements, true, requirement, message),
    do: [%{requirement: requirement, message: message} | requirements]

  defp maybe_missing(requirements, false, _requirement, _message), do: requirements

  defp health_diagnostics(provider, fly_cli_available?, configured?, auth_ready?) do
    []
    |> maybe_health_diagnostic(provider == :fly_machines, "unsupported remote sandbox provider")
    |> maybe_health_diagnostic(fly_cli_available?, "fly or flyctl executable is unavailable")
    |> maybe_health_diagnostic(configured?, "Fly app and machine_id are required")
    |> maybe_health_diagnostic(auth_ready?, "Remote provider credentials are required")
    |> Enum.reverse()
  end

  defp maybe_health_diagnostic(diagnostics, true, _message), do: diagnostics

  defp maybe_health_diagnostic(diagnostics, false, message),
    do: [%{message: message} | diagnostics]

  defp configured?(%Profile{} = profile) do
    app = option(profile.backend_options, :app)
    machine_id = option(profile.backend_options, :machine_id)
    is_binary(app) and app != "" and is_binary(machine_id) and machine_id != ""
  end

  defp auth_configured?(%Profile{} = profile) do
    token_env = option(profile.backend_options, :token_env) || @default_token_env

    is_binary(token_env) and token_env != "" and env_present?(token_env)
  end

  defp credential_policy(%Profile{} = profile) do
    profile.backend_options
    |> option(:credential_policy)
    |> normalize_credential_policy()
  end

  defp normalize_credential_policy(nil), do: :env_token
  defp normalize_credential_policy(:env_token), do: :env_token
  defp normalize_credential_policy("env_token"), do: :env_token
  defp normalize_credential_policy(:ambient_cli_allowed), do: :ambient_cli_allowed
  defp normalize_credential_policy("ambient_cli_allowed"), do: :ambient_cli_allowed
  defp normalize_credential_policy(:none), do: :none
  defp normalize_credential_policy("none"), do: :none
  defp normalize_credential_policy(_other), do: :env_token

  defp env_present?(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> true
      _other -> false
    end
  end

  defp provider(%Profile{} = profile),
    do: profile.backend_options |> option(:provider) |> normalize_provider()

  defp normalize_provider(nil), do: @default_provider
  defp normalize_provider(:fly), do: :fly_machines
  defp normalize_provider("fly"), do: :fly_machines
  defp normalize_provider(:fly_machines), do: :fly_machines
  defp normalize_provider("fly_machines"), do: :fly_machines
  defp normalize_provider(other) when is_atom(other), do: other
  defp normalize_provider(_other), do: :unsupported

  defp provider_runtime(%Profile{} = profile) do
    %{
      app: option(profile.backend_options, :app),
      machine_id: option(profile.backend_options, :machine_id),
      region: option(profile.backend_options, :region),
      image: option(profile.backend_options, :image),
      token_env: option(profile.backend_options, :token_env) || @default_token_env,
      executable: fly_executable(profile),
      credential_policy: credential_policy(profile)
    }
  end

  defp fly_executable(%Profile{} = profile) do
    configured =
      option(profile.backend_options, :executable) || option(profile.backend_options, :flyctl)

    cond do
      is_binary(configured) and configured != "" ->
        System.find_executable(configured)

      executable = System.find_executable("flyctl") ->
        executable

      executable = System.find_executable("fly") ->
        executable

      true ->
        nil
    end
  end

  defp option(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp option(_map, _key), do: nil

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
