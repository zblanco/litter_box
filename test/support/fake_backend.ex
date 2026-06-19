defmodule LitterBox.Test.FakeBackend do
  @moduledoc false

  @behaviour LitterBox.Backend

  alias LitterBox.Capabilities
  alias LitterBox.AttachHandle
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

  @impl true
  def provision(%Profile{} = profile, _opts), do: {:ok, Instance.from_profile(profile)}

  @impl true
  def exec(%Instance{} = instance, %ExecutionRequest{} = request, _opts) do
    ExecutionResult.new(
      status: :pass,
      stdout: request.source || Enum.join(request.argv, " "),
      stderr: "",
      exit_status: 0,
      duration_ms: 1,
      backend: instance.backend,
      isolation_level: instance.isolation_level
    )
  end

  @impl true
  def upload(%Instance{}, _files, _opts), do: {:ok, []}

  @impl true
  def download(%Instance{}, _paths, _opts), do: {:ok, []}

  @impl true
  def snapshot(%Instance{} = instance, _opts), do: {:ok, %{instance_id: instance.id}}

  @impl true
  def reset(%Instance{}, _opts), do: :ok

  @impl true
  def destroy(%Instance{}, _opts), do: :ok

  @impl true
  def health(_opts), do: {:ok, %{available?: true}}

  @impl true
  def open_session(%Profile{} = profile, _opts) do
    instance = Instance.from_profile(profile)

    Session.from_instance(instance,
      capabilities:
        Capabilities.new!(
          exec?: true,
          files?: true,
          checkpoints?: true,
          services?: true,
          proxy?: true,
          leases?: true,
          streaming?: true,
          network_policy?: true,
          persistent_identity?: true,
          metadata:
            Capabilities.attach_metadata(:live_stream,
              stdin_supported?: true,
              stderr_separate?: true,
              state_tier: :persistent_process_host,
              process_host?: true,
              workspace_persistent?: true,
              live_process_stream?: true,
              service_host?: true,
              snapshot_modes: [:microvm_snapshot],
              provider_transport: :fake_stream
            )
        ),
      policy: profile.policy,
      state_model: :checkpointable,
      transport_model: :local_microvm,
      persistent_identity?: true,
      workspace_ref: "workspace://fake"
    )
  end

  @impl true
  def close_session(%Session{}, _opts), do: :ok

  @impl true
  def exec_session(%Session{} = session, %ExecutionRequest{} = request, _opts) do
    ExecutionResult.new(
      status: :pass,
      stdout: request.source,
      stderr: "",
      exit_status: 0,
      duration_ms: 1,
      backend: session.backend,
      isolation_level: session.isolation_level
    )
  end

  @impl true
  def attach_session(%Session{} = session, %ExecutionRequest{} = request, _opts) do
    AttachHandle.new(
      id: "attach-1",
      session_id: session.id,
      backend: session.backend,
      events: [
        session_event(session, :exec_started, %{argv: request.argv}),
        session_event(session, :stdout_chunk, %{chunk: request.source || "", stream: :stdout}),
        session_event(session, :exec_finished, %{exit_status: 0})
      ],
      metadata: %{fake?: true}
    )
  end

  @impl true
  def write_stdin(%AttachHandle{}, input, _opts) when is_binary(input) or is_list(input), do: :ok

  @impl true
  def close_attach(%AttachHandle{}, _opts), do: :ok

  @impl true
  def start_process(%Session{} = session, %ExecutionRequest{} = request, _opts) do
    ProcessHandle.new(
      id: "process-1",
      session_id: session.id,
      backend: session.backend,
      status: :running,
      command: request.argv,
      events: [
        session_event(session, :process_started, %{process_id: "process-1", argv: request.argv}),
        session_event(session, :stdout_chunk, %{chunk: request.source || "", stream: :stdout})
      ],
      metadata: %{fake?: true}
    )
  end

  @impl true
  def list_processes(%Session{} = session, _opts) do
    {:ok,
     [
       ProcessStatus.new!(
         id: "process-1",
         session_id: session.id,
         backend: session.backend,
         status: :running
       )
     ]}
  end

  @impl true
  def process_status(%Session{} = session, %ProcessHandle{} = handle, _opts) do
    ProcessStatus.from_handle(handle, session_id: session.id, status: :running)
  end

  def process_status(%Session{} = session, process_id, _opts) when is_binary(process_id) do
    ProcessStatus.new(
      id: process_id,
      session_id: session.id,
      backend: session.backend,
      status: :running
    )
  end

  @impl true
  def process_events(%ProcessHandle{} = handle, _opts), do: {:ok, ProcessHandle.events(handle)}

  @impl true
  def write_process_stdin(%ProcessHandle{}, input, _opts) when is_binary(input) or is_list(input),
    do: :ok

  @impl true
  def close_process_stdin(%ProcessHandle{}, _opts), do: :ok

  @impl true
  def signal_process(%ProcessHandle{}, signal, _opts) when is_atom(signal) or is_binary(signal),
    do: :ok

  @impl true
  def kill_process(%ProcessHandle{}, _opts), do: :ok

  @impl true
  def wait_process(%ProcessHandle{} = handle, _opts) do
    ProcessStatus.from_handle(handle, status: :exited, exit_status: 0)
  end

  @impl true
  def write_file(%Session{}, path, contents, _opts) do
    FileRef.new(path: path, bytes: IO.iodata_length(contents), sha256: "fake")
  end

  @impl true
  def read_file(%Session{}, path, _opts), do: {:ok, "fake:#{path}"}

  @impl true
  def list_files(%Session{}, path, _opts), do: {:ok, [FileRef.new!(path: path)]}

  @impl true
  def delete_file(%Session{}, _path, _opts), do: :ok

  @impl true
  def checkpoint(%Session{} = session, _spec, _opts) do
    Checkpoint.new(
      id: "checkpoint-1",
      session_id: session.id,
      backend: session.backend,
      ref: "checkpoint://fake/1",
      metadata: %{
        kind: :microvm_snapshot,
        preserves: Checkpoint.preserves(:microvm_snapshot),
        caveats: ["Fake backend models a full microVM snapshot for contract tests."]
      }
    )
  end

  @impl true
  def restore(%Session{} = session, %Checkpoint{}, _opts), do: {:ok, session}
  def restore(%Session{} = session, _checkpoint_ref, _opts), do: {:ok, session}

  @impl true
  def start_service(%Session{} = session, spec, _opts) do
    Service.new(
      id: "service-1",
      session_id: session.id,
      name: to_string(Map.get(Map.new(spec), :name, "fake")),
      status: :running
    )
  end

  @impl true
  def stop_service(%Session{}, _service, _opts), do: :ok

  @impl true
  def list_services(%Session{} = session, _opts) do
    {:ok, [Service.new!(id: "service-1", session_id: session.id, name: "fake", status: :running)]}
  end

  @impl true
  def open_proxy(%Session{} = session, service, _opts) do
    service_id = if is_binary(service), do: service, else: service.id

    Proxy.new(
      id: "proxy-1",
      session_id: session.id,
      backend: session.backend,
      service_id: service_id,
      status: :open,
      url: "http://127.0.0.1:9999",
      local_port: 9999
    )
  end

  @impl true
  def close_proxy(_proxy, _opts), do: :ok

  @impl true
  def acquire_lease(%Session{} = session, resource, _opts) do
    LitterBox.Lease.new(
      id: "lease-1",
      session_id: session.id,
      backend: session.backend,
      resource: resource,
      mode: :exclusive,
      status: :active
    )
  end

  @impl true
  def release_lease(_lease, _opts), do: :ok

  def unsupported_for_test(operation, subject),
    do: LitterBox.Backend.unsupported(operation, subject)

  def error_for_test(message), do: Error.validation(message, source: __MODULE__)

  defp session_event(%Session{} = session, type, payload) do
    LitterBox.SessionEvent.new!(
      id: "#{type}-#{System.unique_integer([:positive])}",
      session_id: session.id,
      type: type,
      payload: payload
    )
  end
end
