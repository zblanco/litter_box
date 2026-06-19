defmodule LitterBox.Backends.Sprites do
  @moduledoc """
  Sprites-backed hosted persistent sandbox backend.

  The adapter talks to the public Sprites HTTP API through an injectable
  requester. WebSocket exec/proxy APIs are represented as stable session/proxy
  metadata in this base adapter; a later adapter can own streaming transports.
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
  alias LitterBox.Instance
  alias LitterBox.ProcessHandle
  alias LitterBox.ProcessStatus
  alias LitterBox.Profile
  alias LitterBox.Proxy
  alias LitterBox.Service
  alias LitterBox.Session

  @default_api_url "https://api.sprites.dev"
  @default_token_env "SPRITES_TOKEN"
  @default_timeout_ms 30_000
  @default_cwd "/home/sprite"
  @runtime_commands %{
    bash: ["sh", "-lc"],
    sh: ["sh", "-lc"],
    python: ["python3", "-c"],
    node: ["node", "-e"],
    elixir: ["elixir", "-e"],
    lua: ["lua", "-e"]
  }

  @impl true
  def provision(%Profile{backend: :sprites} = profile, opts) do
    health = health_for(profile, opts)

    {:ok,
     Instance.from_profile(profile,
       id: Keyword.get(opts, :id),
       state: if(health.available?, do: :ready, else: :unavailable),
       metadata: %{
         security_boundary?: true,
         backend_module: __MODULE__,
         available?: health.available?,
         provider: :sprites,
         api_url: api_url(profile),
         sprite: sprite_name(profile, Keyword.get(opts, :spec, [])),
         token_env: token_env(profile),
         token_present?: token_present?(profile, opts),
         diagnostics: health.diagnostics
       }
     )}
  end

  def provision(%Profile{} = profile, _opts) do
    {:error,
     Error.validation(
       "sprites backend cannot provision profile backend #{inspect(profile.backend)}",
       source: __MODULE__,
       details: %{backend: profile.backend}
     )}
  end

  @impl true
  def exec(%Instance{} = instance, %ExecutionRequest{} = request, opts) do
    with {:ok, session} <-
           Session.from_instance(instance,
             capabilities: session_capabilities(),
             policy: request_policy(request),
             state_model: :service_actor,
             transport_model: :remote_microvm,
             persistent_identity?: true,
             workspace_ref: "sprites://#{option(instance.metadata, :sprite)}",
             metadata: Map.take(instance.metadata, [:api_url, :sprite, :token_env, :provider])
           ) do
      exec_session(session, request, opts)
    end
  end

  @impl true
  def upload(%Instance{}, _files, _opts),
    do: {:error, Error.validation("sprites upload requires an open session", source: __MODULE__)}

  @impl true
  def download(%Instance{}, _paths, _opts),
    do:
      {:error, Error.validation("sprites download requires an open session", source: __MODULE__)}

  @impl true
  def snapshot(%Instance{} = instance, _opts) do
    {:ok,
     %{
       instance_id: instance.id,
       backend: :sprites,
       provider: :sprites,
       stateful?: true,
       sprite: option(instance.metadata, :sprite)
     }}
  end

  @impl true
  def reset(%Instance{}, _opts), do: :ok

  @impl true
  def destroy(%Instance{} = instance, opts) do
    case option(instance.metadata, :sprite) do
      name when is_binary(name) and name != "" ->
        delete_sprite(name, instance.metadata, opts)

      _other ->
        :ok
    end
  end

  @impl true
  def health(opts) do
    profile = Keyword.get(opts, :profile, Profile.new!(backend: :sprites))
    {:ok, health_for(profile, opts)}
  end

  @impl true
  def open_session(%Profile{backend: :sprites} = profile, opts) do
    with :ok <- ensure_configured(profile, opts),
         {:ok, sprite} <- ensure_sprite(profile, Keyword.get(opts, :spec, []), opts),
         {:ok, instance} <-
           provision(profile, Keyword.put(opts, :id, sprite_name(sprite, profile))) do
      Session.from_instance(instance,
        id: sprite_name(sprite, profile),
        capabilities: session_capabilities(),
        policy: profile.policy,
        state_model: :service_actor,
        transport_model: :remote_microvm,
        persistent_identity?: true,
        workspace_ref: "sprites://#{sprite_name(sprite, profile)}",
        metadata: %{
          provider: :sprites,
          sprite: sprite_name(sprite, profile),
          sprite_id: get(sprite, :id, nil),
          organization:
            get(
              sprite,
              :organization,
              get(sprite, :org_slug, option(profile.backend_options, :organization))
            ),
          url: get(sprite, :url, nil),
          status: get(sprite, :status, nil),
          api_url: api_url(profile),
          token_env: token_env(profile),
          create_policy: create_policy(profile),
          default_cwd: @default_cwd
        }
      )
    end
  end

  @impl true
  def close_session(%Session{} = session, opts) do
    if option(session.metadata, :create_policy) == :ephemeral do
      delete_sprite(session.id, session.metadata, opts)
    else
      :ok
    end
  end

  @impl true
  def exec_session(%Session{} = session, %ExecutionRequest{} = request, opts) do
    started = System.monotonic_time(:millisecond)

    with :ok <- ensure_session_configured(session, opts),
         :ok <- write_request_files(session, request, request.files, opts),
         {:ok, argv} <- request_argv(request),
         {:ok, response} <-
           request(
             session_config(session),
             :post,
             "/v1/sprites/#{escape(session.id)}/exec",
             exec_query(argv, request),
             request.stdin,
             opts
           ),
         {:ok, {stdout, stderr, exit_status}} <- exec_output(response) do
      duration_ms = System.monotonic_time(:millisecond) - started
      output = stdout <> stderr

      ExecutionResult.new(
        status: if(exit_status == 0, do: :pass, else: :fail),
        stdout: cap(stdout, request.max_output_bytes),
        stderr: cap(stderr, request.max_output_bytes),
        exit_status: exit_status,
        duration_ms: duration_ms,
        files_changed: Map.keys(request.files || %{}),
        artifacts: [],
        backend: :sprites,
        isolation_level: :remote_microvm,
        diagnostics: diagnostics(output, request.max_output_bytes),
        resource_usage: %{},
        metadata: %{
          sandbox: request.sandbox,
          runtime: request.runtime,
          mode: request.mode,
          network: request.network,
          provider: :sprites,
          sprite: session.id,
          session_id: session.id,
          stateful?: true,
          security_boundary?: true
        }
      )
    end
  end

  @impl true
  def attach_session(%Session{} = session, %ExecutionRequest{} = request, opts) do
    with {:ok, result} <- exec_session(session, request, opts) do
      AttachEvents.terminal_handle(session, request, result,
        metadata: %{provider_transport: :sprites_http_exec}
      )
    end
  end

  @impl true
  def write_stdin(%AttachHandle{}, _input, _opts), do: terminal_attach_stdin_error()

  @impl true
  def close_attach(%AttachHandle{}, _opts), do: :ok

  @impl true
  def start_process(%Session{} = session, %ExecutionRequest{} = request, opts) do
    with :ok <- ensure_session_configured(session, opts),
         {:ok, argv} <- request_argv(request),
         {:ok, handle} <- open_process_websocket(session, request, argv, opts) do
      {:ok, handle}
    end
  end

  @impl true
  def list_processes(%Session{} = session, opts) do
    with :ok <- ensure_session_configured(session, opts),
         {:ok, response} <-
           request(
             session_config(session),
             :get,
             "/v1/sprites/#{escape(session.id)}/exec",
             %{},
             "",
             opts
           ) do
      sessions = if is_list(response), do: response, else: get(response, :sessions, [])
      {:ok, Enum.map(sessions, &process_status_from_session(session, &1))}
    end
  end

  @impl true
  def process_status(%Session{} = session, %ProcessHandle{} = handle, opts),
    do: process_status(session, handle.id, opts)

  def process_status(%Session{} = session, process_id, opts) when is_binary(process_id) do
    with {:ok, statuses} <- list_processes(session, opts) do
      {:ok,
       Enum.find(
         statuses,
         ProcessStatus.new!(id: process_id, session_id: session.id, backend: :sprites),
         fn
           status -> status.id == process_id
         end
       )}
    end
  end

  @impl true
  def process_events(%ProcessHandle{} = handle, _opts), do: {:ok, ProcessHandle.events(handle)}

  @impl true
  def write_process_stdin(%ProcessHandle{metadata: metadata}, input, _opts) do
    cond do
      is_function(Map.get(metadata, :stdin), 1) ->
        normalize_process_callback(Map.fetch!(metadata, :stdin).(IO.iodata_to_binary(input)))

      is_function(Map.get(metadata, :writer), 1) ->
        normalize_process_callback(Map.fetch!(metadata, :writer).(IO.iodata_to_binary(input)))

      true ->
        {:error,
         Error.validation("sprites process handle is not writable",
           source: __MODULE__,
           details: %{backend: :sprites}
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  @impl true
  def close_process_stdin(%ProcessHandle{metadata: metadata}, _opts) do
    cond do
      is_function(Map.get(metadata, :stdin_eof), 0) ->
        normalize_process_callback(Map.fetch!(metadata, :stdin_eof).())

      is_function(Map.get(metadata, :stdin_eof), 1) ->
        normalize_process_callback(Map.fetch!(metadata, :stdin_eof).(<<4>>))

      is_function(Map.get(metadata, :writer), 1) ->
        normalize_process_callback(Map.fetch!(metadata, :writer).(<<4>>))

      true ->
        {:error,
         Error.validation("sprites process handle does not support stdin close",
           source: __MODULE__,
           details: %{backend: :sprites}
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  @impl true
  def signal_process(%ProcessHandle{metadata: metadata} = handle, signal, opts) do
    session_id = Map.get(metadata, :sprite) || handle.session_id
    provider_session_id = Map.get(metadata, :provider_session_id) || handle.id

    with {:ok, _events} <-
           kill_exec_session(session_id, provider_session_id, to_string(signal), metadata, opts) do
      :ok
    end
  end

  @impl true
  def kill_process(%ProcessHandle{} = handle, opts) do
    case signal_process(handle, "SIGTERM", opts) do
      :ok -> close_process_handle(handle.metadata)
      {:error, _error} -> close_process_handle(handle.metadata)
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
    with :ok <- ensure_session_configured(session, opts),
         {:ok, response} <-
           request(
             session_config(session),
             :put,
             "/v1/sprites/#{escape(session.id)}/fs/write",
             %{path: to_string(path), workingDir: working_dir(opts), mkdir: true},
             IO.iodata_to_binary(contents),
             opts
           ) do
      bytes = get(response, :size, byte_size(IO.iodata_to_binary(contents)))

      FileRef.new(
        path: get(response, :path, to_string(path)),
        kind: :file,
        bytes: bytes,
        sha256: Base.encode16(:crypto.hash(:sha256, IO.iodata_to_binary(contents)), case: :lower),
        metadata: %{provider: :sprites}
      )
    end
  end

  @impl true
  def read_file(%Session{} = session, path, opts) do
    with :ok <- ensure_session_configured(session, opts),
         {:ok, response} <-
           request(
             session_config(session),
             :get,
             "/v1/sprites/#{escape(session.id)}/fs/read",
             %{path: to_string(path), workingDir: working_dir(opts)},
             "",
             opts
           ) do
      {:ok, raw_body(response)}
    end
  end

  @impl true
  def list_files(%Session{} = session, path, opts) do
    with :ok <- ensure_session_configured(session, opts),
         {:ok, response} <-
           request(
             session_config(session),
             :get,
             "/v1/sprites/#{escape(session.id)}/fs/list",
             %{path: to_string(path), workingDir: working_dir(opts)},
             "",
             opts
           ) do
      entries = get(response, :entries, [])

      refs =
        Enum.map(entries, fn entry ->
          FileRef.new!(
            path: get(entry, :path, get(entry, :name, "")),
            kind: normalize_file_kind(get(entry, :type, get(entry, :kind, :unknown))),
            bytes: get(entry, :size, nil),
            metadata: entry
          )
        end)

      {:ok, refs}
    end
  end

  @impl true
  def delete_file(%Session{} = session, path, opts) do
    with :ok <- ensure_session_configured(session, opts),
         {:ok, _response} <-
           request(
             session_config(session),
             :delete,
             "/v1/sprites/#{escape(session.id)}/fs/delete",
             %{path: to_string(path), workingDir: working_dir(opts)},
             "",
             opts
           ) do
      :ok
    end
  end

  @impl true
  def checkpoint(%Session{} = session, spec, opts) do
    comment = option(spec_map(spec), :comment) || option(spec_map(spec), :name)

    with :ok <- ensure_session_configured(session, opts),
         {:ok, response} <-
           request(
             session_config(session),
             :post,
             "/v1/sprites/#{escape(session.id)}/checkpoint",
             %{},
             Jason.encode!(%{comment: comment}),
             opts
           ) do
      events = ndjson_events(response)

      checkpoint_id =
        checkpoint_id_from_events(events) || "checkpoint-#{System.unique_integer([:positive])}"

      Checkpoint.new(
        id: checkpoint_id,
        session_id: session.id,
        backend: :sprites,
        ref: "sprites://#{session.id}/checkpoints/#{checkpoint_id}",
        created_at: DateTime.utc_now(),
        metadata: %{
          kind: :provider_checkpoint,
          provider: :sprites,
          preserves: Checkpoint.preserves(:provider_checkpoint),
          caveats: [
            "Sprites provider checkpoints may preserve provider-managed runtime state, but process, service, and connection preservation is provider-dependent."
          ],
          events: events,
          comment: comment
        }
      )
    end
  end

  @impl true
  def restore(%Session{} = session, %Checkpoint{} = checkpoint, opts) do
    with :ok <- validate_checkpoint(session, checkpoint),
         :ok <- restore_checkpoint(session, checkpoint.id, opts) do
      {:ok, session}
    end
  end

  def restore(%Session{} = session, checkpoint_id, opts) when is_binary(checkpoint_id) do
    with :ok <- restore_checkpoint(session, checkpoint_id, opts) do
      {:ok, session}
    end
  end

  @impl true
  def start_service(%Session{} = session, spec, opts) do
    spec = spec_map(spec)
    name = option(spec, :name) || "service-#{System.unique_integer([:positive])}"
    cmd = option(spec, :cmd) || option(spec, :command)
    args = option(spec, :args) || []

    with :ok <- ensure_session_configured(session, opts),
         :ok <- require_string(cmd, :cmd),
         {:ok, response} <-
           request(
             session_config(session),
             :post,
             "/v1/sprites/#{escape(session.id)}/services",
             %{},
             Jason.encode!(%{
               name: name,
               cmd: cmd,
               args: args,
               http_port: option(spec, :http_port),
               needs: option(spec, :needs) || []
             }),
             opts
           ) do
      service_from_response(session, response)
    end
  end

  @impl true
  def stop_service(%Session{} = session, %Service{} = service, opts),
    do: stop_service(session, service.name, opts)

  def stop_service(%Session{} = session, service_name, opts) do
    with :ok <- ensure_session_configured(session, opts),
         {:ok, _response} <-
           request(
             session_config(session),
             :post,
             "/v1/sprites/#{escape(session.id)}/services/#{escape(service_name)}/stop",
             %{},
             "",
             opts
           ) do
      :ok
    end
  end

  @impl true
  def list_services(%Session{} = session, opts) do
    with :ok <- ensure_session_configured(session, opts),
         {:ok, response} <-
           request(
             session_config(session),
             :get,
             "/v1/sprites/#{escape(session.id)}/services",
             %{},
             "",
             opts
           ) do
      services = if is_list(response), do: response, else: get(response, :services, [])
      {:ok, Enum.map(services, &service_from_response!(session, &1))}
    end
  end

  @impl true
  def open_proxy(%Session{} = session, %Service{} = service, opts),
    do: open_proxy(session, service.name, Keyword.put_new(opts, :port, service_port(service)))

  def open_proxy(%Session{} = session, service_id, opts) do
    port = Keyword.get(opts, :port) || 80
    host = Keyword.get(opts, :host, "localhost")
    api_url = session_config(session).api_url |> String.replace_prefix("https://", "wss://")

    Proxy.new(
      id: "sprites-proxy-#{session.id}-#{service_id}-#{port}",
      session_id: session.id,
      backend: :sprites,
      service_id: to_string(service_id),
      status: :open,
      url: "#{api_url}/v1/sprites/#{URI.encode_www_form(session.id)}/proxy",
      local_port: nil,
      metadata: %{provider: :sprites, host: host, port: port, protocol: :websocket_tcp_proxy}
    )
  end

  @impl true
  def close_proxy(%Proxy{}, _opts), do: :ok
  def close_proxy(_proxy, _opts), do: :ok

  defp open_process_websocket(%Session{} = session, %ExecutionRequest{} = request, argv, opts) do
    websocket_open = Keyword.get(opts, :websocket_open, &open_websocket_exec/4)
    config = session_config(session)
    query = exec_websocket_query(argv, request, opts)
    url = websocket_url(config.api_url, "/v1/sprites/#{escape(session.id)}/exec", query)

    with {:ok, transport} <- websocket_open.(config, url, query, request_opts(config, opts)) do
      provider_session_id = transport_session_id(transport)
      process_id = provider_session_id || "sprites-process-#{System.unique_integer([:positive])}"

      ProcessHandle.new(
        id: process_id,
        session_id: session.id,
        backend: session.backend,
        status: :running,
        command: argv,
        events: process_events_from_transport(session, request, process_id, transport),
        metadata:
          %{
            streaming_live?: true,
            provider_transport: :sprites_websocket_exec,
            provider_session_id: provider_session_id,
            sprite: session.id,
            api_url: config.api_url,
            token_env: config.token_env
          }
          |> maybe_put_callback(:stdin, get(transport, :stdin, nil))
          |> maybe_put_callback(:stdin_eof, get(transport, :stdin_eof, nil))
          |> maybe_put_callback(:writer, get(transport, :writer, nil))
          |> maybe_put_callback(:closer, get(transport, :closer, nil))
      )
    end
  end

  defp open_websocket_exec(_config, url, _query, opts) do
    case System.find_executable("websocat") do
      nil ->
        missing_websocket_open()

      executable ->
        args =
          [url] ++
            (opts
             |> Keyword.get(:headers, [])
             |> Enum.flat_map(fn {key, value} -> ["-H", "#{key}: #{value}"] end))

        port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args])

        {:ok,
         %{
           transport: :websocat,
           events: websocket_port_events(port),
           writer: fn input -> Port.command(port, <<0>> <> IO.iodata_to_binary(input)) end,
           stdin_eof: fn -> Port.command(port, <<4>>) end,
           closer: fn -> Port.close(port) end
         }}
    end
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp missing_websocket_open do
    {:error,
     Error.validation("sprites live process WebSocket adapter is not configured",
       source: __MODULE__,
       details: %{
         backend: :sprites,
         operation: :start_process,
         provider_transport: :sprites_websocket_exec
       }
     )}
  end

  defp websocket_port_events(port) do
    Stream.resource(
      fn -> %{port: port, finished?: false} end,
      &next_websocket_port_event/1,
      fn state ->
        unless state.finished?,
          do: close_process_handle(%{closer: fn -> Port.close(state.port) end})
      end
    )
  end

  defp next_websocket_port_event(%{port: port} = state) do
    receive do
      {^port, {:data, data}} ->
        {[data], state}

      {^port, {:exit_status, status}} ->
        {[<<3, normalize_exit_status_byte(status)>>], %{state | finished?: true}}
    end
  end

  defp normalize_exit_status_byte(status) when is_integer(status) and status in 0..255, do: status
  defp normalize_exit_status_byte(_status), do: 1

  defp exec_websocket_query(argv, %ExecutionRequest{} = request, opts) do
    %{
      cmd: argv,
      dir: request.cwd,
      stdin: true,
      tty: Keyword.get(opts, :tty?, false),
      max_run_after_disconnect: Keyword.get(opts, :max_run_after_disconnect, "10s")
    }
  end

  defp websocket_url(api_url, path, query) do
    api_url
    |> String.replace_prefix("https://", "wss://")
    |> String.replace_prefix("http://", "ws://")
    |> request_url(path, query)
  end

  defp transport_session_id(transport) do
    case get(transport, :session_id, get(transport, :id, nil)) do
      id when is_integer(id) -> Integer.to_string(id)
      id when is_binary(id) and id != "" -> id
      _other -> nil
    end
  end

  defp process_events_from_transport(%Session{} = session, request, process_id, transport) do
    started =
      AttachEvents.event(session, :process_started, %{
        process_id: process_id,
        provider_session_id: transport_session_id(transport),
        runtime: request.runtime,
        mode: request.mode,
        argv: request.argv,
        cwd: request.cwd,
        sprite: session.id
      })

    events =
      transport
      |> get(:events, [])
      |> Stream.map(&normalize_process_event(session, process_id, &1))
      |> Stream.reject(&is_nil/1)

    Stream.concat([started], events)
  end

  defp normalize_process_event(_session, _process_id, %LitterBox.SessionEvent{} = event),
    do: event

  defp normalize_process_event(session, _process_id, <<1, chunk::binary>>),
    do: AttachEvents.chunk_event(session, :stdout_chunk, chunk)

  defp normalize_process_event(session, _process_id, <<2, chunk::binary>>),
    do: AttachEvents.chunk_event(session, :stderr_chunk, chunk)

  defp normalize_process_event(session, process_id, <<3, exit_status>>),
    do: process_finished_event(session, process_id, exit_status)

  defp normalize_process_event(session, _process_id, %{type: type, chunk: chunk})
       when type in [:stdout, :stdout_chunk, "stdout", "stdout_chunk"],
       do: AttachEvents.chunk_event(session, :stdout_chunk, to_string(chunk))

  defp normalize_process_event(session, _process_id, %{type: type, chunk: chunk})
       when type in [:stderr, :stderr_chunk, "stderr", "stderr_chunk"],
       do: AttachEvents.chunk_event(session, :stderr_chunk, to_string(chunk))

  defp normalize_process_event(session, process_id, %{type: type} = event)
       when type in [:exit, :process_finished, "exit", "process_finished"] do
    process_finished_event(
      session,
      process_id,
      get(event, :exit_status, get(event, :exit_code, 0))
    )
  end

  defp normalize_process_event(_session, _process_id, _event), do: nil

  defp process_finished_event(session, process_id, exit_status) do
    exit_status =
      case normalize_exit_status(exit_status) do
        {:ok, value} -> value
        {:error, _error} -> 1
      end

    AttachEvents.event(session, :process_finished, %{
      process_id: process_id,
      status: if(exit_status == 0, do: :exited, else: :failed),
      exit_status: exit_status,
      provider: :sprites,
      sprite: session.id
    })
  end

  defp maybe_put_callback(metadata, _key, nil), do: metadata

  defp maybe_put_callback(metadata, key, callback) when is_function(callback),
    do: Map.put(metadata, key, callback)

  defp maybe_put_callback(metadata, _key, _callback), do: metadata

  defp normalize_process_callback(:ok), do: :ok
  defp normalize_process_callback({:ok, _value}), do: :ok
  defp normalize_process_callback({:error, %Error{} = error}), do: {:error, error}

  defp normalize_process_callback({:error, reason}),
    do: {:error, Error.from_reason(reason, source: __MODULE__)}

  defp normalize_process_callback(_other), do: :ok

  defp close_process_handle(metadata) do
    case Map.get(metadata, :closer) do
      closer when is_function(closer, 0) -> normalize_process_callback(closer.())
      closer when is_function(closer, 1) -> normalize_process_callback(closer.(:close))
      _other -> :ok
    end
  rescue
    _exception -> :ok
  end

  defp kill_exec_session(sprite, provider_session_id, signal, metadata, opts) do
    config = %{
      api_url: Map.get(metadata, :api_url, @default_api_url),
      token_env: Map.get(metadata, :token_env, @default_token_env)
    }

    with {:ok, response} <-
           request(
             config,
             :post,
             "/v1/sprites/#{escape(sprite)}/exec/#{escape(provider_session_id)}/kill",
             %{signal: signal},
             "",
             opts
           ) do
      {:ok, ndjson_events(response)}
    end
  end

  defp process_status_from_session(%Session{} = session, exec_session) do
    id = get(exec_session, :id, "exec-#{System.unique_integer([:positive])}") |> to_string()

    ProcessStatus.new!(
      id: id,
      session_id: session.id,
      backend: :sprites,
      status:
        if(truthy?(get(exec_session, :is_active, get(exec_session, :isActive, false))),
          do: :running,
          else: :unknown
        ),
      pid: get(exec_session, :pid, nil),
      metadata: %{
        provider_transport: :sprites_websocket_exec,
        command: get(exec_session, :command, nil),
        tty: get(exec_session, :tty, nil),
        created: get(exec_session, :created, nil),
        last_activity: get(exec_session, :last_activity, get(exec_session, :lastActivity, nil))
      }
    )
  end

  defp health_for(%Profile{} = profile, opts) do
    configured? = configured?(profile)
    token_present? = token_present?(profile, opts)
    available? = configured? and token_present?

    %{
      name: :sprites,
      available?: available?,
      host_available?: true,
      configured?: configured?,
      exec_ready?: available?,
      provider: :sprites,
      api_url: api_url(profile),
      token_env: token_env(profile),
      token_present?: token_present?,
      token_value: :redacted,
      process_transport: %{
        native: :sprites_websocket_exec,
        default_adapter: :websocat,
        default_adapter_available?: websocat_available?()
      },
      runtimes: [:bash, :sh, :python, :node, :elixir, :lua],
      isolation_level: :remote_microvm,
      transport_model: :remote_microvm,
      state_model: :service_actor,
      network: %{default: :restricted, provider_managed?: true},
      stateful?: true,
      security_boundary?: true,
      capabilities: Capabilities.to_map(session_capabilities()),
      missing_requirements: missing_requirements(configured?, token_present?, profile),
      diagnostics: diagnostics(configured?, token_present?, profile)
    }
  end

  defp ensure_configured(%Profile{} = profile, opts) do
    case health_for(profile, opts) do
      %{available?: true} ->
        :ok

      health ->
        {:error,
         Error.validation("sprites sandbox provider is not available for execution",
           source: __MODULE__,
           details: %{
             missing_requirements: health.missing_requirements,
             diagnostics: health.diagnostics,
             token_env: health.token_env,
             token_value: :redacted
           }
         )}
    end
  end

  defp ensure_session_configured(%Session{} = session, opts) do
    config = session_config(session)

    if token(config, opts) do
      :ok
    else
      {:error,
       Error.validation("sprites sandbox token env is required for execution",
         source: __MODULE__,
         details: %{token_env: config.token_env, token_value: :redacted}
       )}
    end
  end

  defp ensure_sprite(%Profile{} = profile, spec, opts) do
    name = sprite_name(profile, spec)

    case create_policy(profile) do
      policy when policy in [:create, :ephemeral] ->
        create_sprite(name, profile, opts)

      :create_if_missing ->
        case create_sprite(name, profile, opts) do
          {:ok, sprite} ->
            {:ok, sprite}

          {:error, %{details: %{status: 409}}} ->
            get_sprite(name, profile, opts)

          {:error, error} ->
            {:error, error}
        end

      :verify_existing ->
        get_sprite(name, profile, opts)

      :use_existing ->
        {:ok, %{"name" => name, "organization" => option(profile.backend_options, :organization)}}
    end
  end

  defp create_sprite(name, profile, opts) do
    body =
      %{name: name}
      |> maybe_put(:url_settings, option(profile.backend_options, :url_settings))
      |> Jason.encode!()

    request(config(profile), :post, "/v1/sprites", %{}, body, opts)
  end

  defp get_sprite(name, profile, opts),
    do: request(config(profile), :get, "/v1/sprites/#{escape(name)}", %{}, "", opts)

  defp delete_sprite(name, metadata, opts) do
    config = %{
      api_url: option(metadata, :api_url) || @default_api_url,
      token_env: option(metadata, :token_env) || @default_token_env
    }

    case request(config, :delete, "/v1/sprites/#{escape(name)}", %{}, "", opts) do
      {:ok, _response} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp restore_checkpoint(%Session{} = session, checkpoint_id, opts) do
    with :ok <- ensure_session_configured(session, opts),
         {:ok, _response} <-
           request(
             session_config(session),
             :post,
             "/v1/sprites/#{escape(session.id)}/checkpoints/#{escape(checkpoint_id)}/restore",
             %{},
             "",
             opts
           ) do
      :ok
    end
  end

  defp request(config, method, path, query, body, opts) do
    requester = Keyword.get(opts, :requester, &http_request/6)

    requester.(method, config, path, query, body, request_opts(config, opts))
    |> normalize_response()
  end

  defp request_opts(config, opts) do
    [
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      headers: auth_headers(config, opts)
    ]
  end

  defp http_request(method, config, path, query, body, opts) do
    url = request_url(config.api_url, path, query)
    headers = Keyword.get(opts, :headers, [])
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    request_opts =
      maybe_put_req_body(
        [
          method: method,
          url: url,
          headers: headers,
          receive_timeout: timeout,
          decode_body: false
        ],
        method,
        path,
        body
      )

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:ok, %{status: status, body: response_body}}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp maybe_put_req_body(opts, method, _path, _body) when method in [:get, :delete], do: opts

  defp maybe_put_req_body(opts, :put, path, body) do
    content_type =
      if String.ends_with?(path, "/fs/write"),
        do: "application/octet-stream",
        else: "application/json"

    opts
    |> Keyword.put(:body, body)
    |> Keyword.put(:headers, put_content_type(opts[:headers] || [], content_type))
  end

  defp maybe_put_req_body(opts, _method, _path, body) do
    opts
    |> Keyword.put(:body, body)
    |> Keyword.put(:headers, put_content_type(opts[:headers] || [], "application/json"))
  end

  defp put_content_type(headers, content_type) do
    if Enum.any?(headers, fn {key, _value} ->
         String.downcase(to_string(key)) == "content-type"
       end) do
      headers
    else
      [{"content-type", content_type} | headers]
    end
  end

  defp normalize_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, decode_body(body)}
  end

  defp normalize_response({:ok, %{status: 204}}), do: {:ok, %{}}

  defp normalize_response({:ok, %{status: status, body: body}}) do
    {:error,
     Error.validation("sprites API request failed",
       source: __MODULE__,
       details: %{status: status, body: redacted_body(body)}
     )}
  end

  defp normalize_response({:ok, body}) when is_map(body) or is_list(body) or is_binary(body),
    do: {:ok, decode_body(body)}

  defp normalize_response({:error, %Error{} = error}), do: {:error, error}

  defp normalize_response({:error, reason}),
    do: {:error, Error.from_reason(reason, source: __MODULE__)}

  defp decode_body(body) when is_map(body) or is_list(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _error} -> body
    end
  end

  defp exec_query(argv, %ExecutionRequest{} = request) do
    %{
      cmd: argv,
      dir: request.cwd,
      stdin: request.stdin not in [nil, ""]
    }
  end

  defp exec_output(response) when is_map(response) do
    stdout = get(response, :stdout, get(response, :output, ""))
    stderr = get(response, :stderr, "")
    exit_status = get(response, :exit_status, get(response, :exit_code, get(response, :code, 0)))

    with {:ok, exit_status} <- normalize_exit_status(exit_status) do
      {:ok, {to_string(stdout || ""), to_string(stderr || ""), exit_status}}
    end
  end

  defp exec_output(response) when is_binary(response) do
    case binary_exec_output(response) do
      {:ok, output} -> {:ok, output}
      :error -> {:ok, {response, "", 0}}
    end
  end

  defp exec_output(_response), do: {:ok, {"", "", 0}}

  defp binary_exec_output(response) when is_binary(response) do
    decode_exec_frames(response, "", "", nil)
  end

  defp decode_exec_frames(<<>>, stdout, stderr, exit_status) when is_integer(exit_status),
    do: {:ok, {stdout, stderr, exit_status}}

  defp decode_exec_frames(<<3, exit_status>>, stdout, stderr, _exit_status),
    do: {:ok, {stdout, stderr, exit_status}}

  defp decode_exec_frames(<<stream, rest::binary>>, stdout, stderr, exit_status)
       when stream in [1, 2] do
    case split_exec_payload(rest) do
      {:ok, payload, rest} ->
        case stream do
          1 -> decode_exec_frames(rest, stdout <> payload, stderr, exit_status)
          2 -> decode_exec_frames(rest, stdout, stderr <> payload, exit_status)
        end

      :error ->
        :error
    end
  end

  defp decode_exec_frames(_response, _stdout, _stderr, _exit_status), do: :error

  defp split_exec_payload(binary) do
    case next_exec_frame_offset(binary, 0) do
      nil ->
        :error

      offset ->
        <<payload::binary-size(offset), rest::binary>> = binary
        {:ok, payload, rest}
    end
  end

  defp next_exec_frame_offset(<<>>, _offset), do: nil
  defp next_exec_frame_offset(<<marker, _rest::binary>>, offset) when marker in [1, 2], do: offset
  defp next_exec_frame_offset(<<3, _exit_status>>, offset), do: offset

  defp next_exec_frame_offset(<<_byte, rest::binary>>, offset),
    do: next_exec_frame_offset(rest, offset + 1)

  defp request_argv(%ExecutionRequest{mode: :command, argv: argv}) when argv != [],
    do: {:ok, argv}

  defp request_argv(%ExecutionRequest{mode: :command}) do
    {:error, Error.validation("sprites command request requires argv", source: __MODULE__)}
  end

  defp request_argv(%ExecutionRequest{mode: :script, runtime: runtime, source: source}) do
    case Map.fetch(@runtime_commands, runtime) do
      {:ok, command} -> {:ok, command ++ [source]}
      :error -> {:error, Error.validation("unsupported sprites runtime", source: __MODULE__)}
    end
  end

  defp write_request_files(_session, _request, files, _opts) when files in [%{}, nil], do: :ok

  defp write_request_files(%Session{} = session, %ExecutionRequest{} = request, files, opts) do
    Enum.reduce_while(files, :ok, fn {path, contents}, :ok ->
      with {:ok, path} <- request_file_path(request.cwd, path),
           {:ok, _ref} <-
             write_file(session, path, contents, Keyword.put(opts, :working_dir, request.cwd)) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp request_file_path(cwd, path) do
    path = to_string(path)
    cwd = Path.expand(cwd || "/workspace")

    cond do
      path == "" ->
        {:error,
         Error.validation("sprites inline file path must be non-empty", source: __MODULE__)}

      String.starts_with?(path, "/") ->
        {:error,
         Error.validation("sprites inline file path must be relative to the request cwd",
           source: __MODULE__,
           details: %{path: path, cwd: cwd}
         )}

      true ->
        guest_path = Path.expand(path, cwd)

        if guest_path != cwd and String.starts_with?(guest_path, cwd <> "/") do
          {:ok, path}
        else
          {:error,
           Error.validation("sprites inline file path escapes the request cwd",
             source: __MODULE__,
             details: %{path: path, cwd: cwd}
           )}
        end
    end
  end

  defp session_capabilities do
    Capabilities.new!(
      exec?: true,
      files?: false,
      inline_files?: true,
      artifacts?: false,
      session_files?: true,
      checkpoints?: true,
      services?: true,
      proxy?: true,
      leases?: false,
      streaming?: true,
      network_policy?: true,
      persistent_identity?: true,
      metadata:
        Capabilities.attach_metadata(:terminal_adapter,
          provider_transport: :sprites_http_exec,
          restricted_egress_supported?: false,
          default_cwd: @default_cwd,
          state_tier: :service_actor,
          process_host?: true,
          workspace_persistent?: true,
          live_process_stream?: true,
          service_host?: true,
          snapshot_modes: [:provider_checkpoint]
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
      isolation_minimum: :remote_microvm,
      persist_changes?: true
    )
  end

  defp config(%Profile{} = profile) do
    %{api_url: api_url(profile), token_env: token_env(profile)}
  end

  defp session_config(%Session{} = session) do
    %{
      api_url: option(session.metadata, :api_url) || @default_api_url,
      token_env: option(session.metadata, :token_env) || @default_token_env
    }
  end

  defp auth_headers(config, opts) do
    case token(config, opts) do
      token when is_binary(token) -> [{"authorization", "Bearer #{token}"}]
      _other -> []
    end
  end

  defp token(config, opts) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    env.(config.token_env)
  end

  defp configured?(%Profile{} = profile), do: is_binary(sprite_name(profile, []))

  defp token_present?(%Profile{} = profile, opts) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    token = env.(token_env(profile))
    is_binary(token) and token != ""
  end

  defp websocat_available?, do: is_binary(System.find_executable("websocat"))

  defp missing_requirements(configured?, token_present?, profile) do
    []
    |> maybe_missing(not configured?, :sprite, "Sprites profile requires a sprite name")
    |> maybe_missing(
      not token_present?,
      :auth,
      "Sprites token env is required: #{token_env(profile)}"
    )
    |> Enum.reverse()
  end

  defp diagnostics(configured?, token_present?, profile) do
    []
    |> maybe_diagnostic(configured?, "Sprites profile requires a sprite name")
    |> maybe_diagnostic(token_present?, "Sprites token env is required: #{token_env(profile)}")
    |> Enum.reverse()
  end

  defp maybe_missing(requirements, true, requirement, message),
    do: [%{requirement: requirement, message: message} | requirements]

  defp maybe_missing(requirements, false, _requirement, _message), do: requirements

  defp maybe_diagnostic(diagnostics, true, _message), do: diagnostics
  defp maybe_diagnostic(diagnostics, false, message), do: [%{message: message} | diagnostics]

  defp api_url(%Profile{} = profile),
    do: option(profile.backend_options, :api_url) || @default_api_url

  defp token_env(%Profile{} = profile),
    do: option(profile.backend_options, :token_env) || @default_token_env

  defp sprite_name(%Profile{} = profile, spec) do
    option(spec_map(spec), :sprite) || option(profile.backend_options, :sprite) ||
      option(profile.backend_options, :name) || Atom.to_string(profile.name)
  end

  defp sprite_name(sprite, %Profile{} = profile) when is_map(sprite),
    do: get(sprite, :name, sprite_name(profile, []))

  defp create_policy(%Profile{} = profile) do
    case option(profile.backend_options, :create_policy) ||
           option(profile.backend_options, :lifecycle) do
      "create" -> :create
      :create -> :create
      "create_if_missing" -> :create_if_missing
      :create_if_missing -> :create_if_missing
      "verify_existing" -> :verify_existing
      :verify_existing -> :verify_existing
      "ephemeral" -> :ephemeral
      :ephemeral -> :ephemeral
      _other -> :use_existing
    end
  end

  defp validate_checkpoint(%Session{} = session, %Checkpoint{} = checkpoint) do
    cond do
      checkpoint.session_id != session.id ->
        {:error,
         Error.validation("checkpoint belongs to a different sandbox session", source: __MODULE__)}

      checkpoint.backend != :sprites ->
        {:error,
         Error.validation("checkpoint belongs to a different sandbox backend", source: __MODULE__)}

      true ->
        :ok
    end
  end

  defp service_from_response(%Session{} = session, response),
    do: Service.new(service_attrs(session, response))

  defp service_from_response!(%Session{} = session, response),
    do: Service.new!(service_attrs(session, response))

  defp service_attrs(%Session{} = session, response) do
    name = get(response, :name, "service-#{System.unique_integer([:positive])}")
    state = get(response, :state, %{})
    port = get(response, :http_port, nil)

    %{
      id: name,
      session_id: session.id,
      name: name,
      status: normalize_service_status(get(state, :status, get(response, :status, :running))),
      ports: if(is_integer(port), do: [%{port: port, protocol: :http}], else: []),
      metadata: response
    }
  end

  defp service_port(%Service{ports: [%{port: port} | _]}), do: port
  defp service_port(_service), do: 80

  defp normalize_service_status(status) when status in [:starting, :running, :stopped, :failed],
    do: status

  defp normalize_service_status("starting"), do: :starting
  defp normalize_service_status("running"), do: :running
  defp normalize_service_status("stopping"), do: :running
  defp normalize_service_status("stopped"), do: :stopped
  defp normalize_service_status("failed"), do: :failed
  defp normalize_service_status(_status), do: :running

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp normalize_file_kind("dir"), do: :directory
  defp normalize_file_kind("directory"), do: :directory
  defp normalize_file_kind("file"), do: :file
  defp normalize_file_kind("symlink"), do: :symlink
  defp normalize_file_kind(kind) when kind in [:file, :directory, :symlink, :unknown], do: kind
  defp normalize_file_kind(_kind), do: :unknown

  defp ndjson_events(response) when is_binary(response) do
    response
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, event} -> event
        {:error, _error} -> %{"type" => "text", "data" => line}
      end
    end)
  end

  defp ndjson_events(response) when is_list(response), do: response
  defp ndjson_events(response) when is_map(response), do: [response]
  defp ndjson_events(_response), do: []

  defp checkpoint_id_from_events(events) do
    Enum.find_value(events, fn event ->
      get(event, :id, nil) || get(event, :checkpoint_id, nil) ||
        checkpoint_id_from_text(get(event, :data, ""))
    end)
  end

  defp checkpoint_id_from_text(text) when is_binary(text) do
    case Regex.run(~r/Checkpoint\s+([A-Za-z0-9_.-]+)/, text) do
      [_, id] -> id
      _other -> nil
    end
  end

  defp checkpoint_id_from_text(_text), do: nil

  defp request_url(api_url, path, query) do
    query =
      query
      |> Enum.flat_map(fn
        {_key, nil} -> []
        {key, values} when is_list(values) -> Enum.map(values, &{key, &1})
        {key, value} -> [{key, value}]
      end)
      |> URI.encode_query()

    base = String.trim_trailing(api_url, "/") <> path
    if query == "", do: base, else: base <> "?" <> query
  end

  defp raw_body(value) when is_binary(value), do: value
  defp raw_body(value), do: Jason.encode!(value)

  defp redacted_body(body) when is_binary(body),
    do: String.replace(body, ~r/Bearer\s+\S+/, "Bearer [REDACTED]")

  defp redacted_body(body), do: body

  defp working_dir(opts), do: Keyword.get(opts, :working_dir, @default_cwd)
  defp escape(value), do: URI.encode_www_form(to_string(value))
  defp normalize_exit_status(value) when is_integer(value), do: {:ok, value}

  defp normalize_exit_status(value) when is_binary(value) do
    case Integer.parse(value) do
      {status, ""} ->
        {:ok, status}

      _other ->
        {:error,
         Error.validation("invalid sprites exec exit status",
           source: __MODULE__,
           details: %{exit_status: value}
         )}
    end
  end

  defp normalize_exit_status(nil), do: {:ok, 0}

  defp normalize_exit_status(value) do
    {:error,
     Error.validation("invalid sprites exec exit status",
       source: __MODULE__,
       details: %{exit_status: value}
     )}
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

  defp require_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp require_string(value, field),
    do:
      {:error,
       Error.validation("sprites #{field} must be a non-empty string",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}

  defp spec_map(value) when is_map(value), do: value
  defp spec_map(value) when is_list(value), do: Map.new(value)
  defp spec_map(_value), do: %{}
  defp option(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp option(_map, _key), do: nil

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
