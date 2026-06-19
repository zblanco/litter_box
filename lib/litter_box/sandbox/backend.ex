defmodule LitterBox.Backend do
  @moduledoc """
  Behaviour implemented by sandbox backends.
  """

  alias LitterBox.Error
  alias LitterBox.AttachHandle
  alias LitterBox.ExecutionRequest
  alias LitterBox.ExecutionResult
  alias LitterBox.FileRef
  alias LitterBox.Instance
  alias LitterBox.ProcessHandle
  alias LitterBox.ProcessStatus
  alias LitterBox.Profile
  alias LitterBox.Session

  @callback provision(Profile.t(), keyword()) :: {:ok, Instance.t()} | {:error, Error.t()}
  @callback exec(Instance.t(), ExecutionRequest.t(), keyword()) ::
              {:ok, ExecutionResult.t()} | {:error, Error.t()}
  @callback upload(Instance.t(), list(), keyword()) :: {:ok, list()} | {:error, Error.t()}
  @callback download(Instance.t(), list(), keyword()) :: {:ok, list()} | {:error, Error.t()}
  @callback snapshot(Instance.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  @callback reset(Instance.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback destroy(Instance.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback health(keyword()) :: {:ok, map()} | {:error, Error.t()}

  @callback open_session(Profile.t(), keyword()) :: {:ok, Session.t()} | {:error, Error.t()}
  @callback close_session(Session.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback exec_session(Session.t(), ExecutionRequest.t(), keyword()) ::
              {:ok, ExecutionResult.t()} | {:error, Error.t()}
  @callback attach_session(Session.t(), ExecutionRequest.t(), keyword()) ::
              {:ok, AttachHandle.t()} | {:error, Error.t()}
  @callback write_stdin(AttachHandle.t(), iodata(), keyword()) :: :ok | {:error, Error.t()}
  @callback close_attach(AttachHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback start_process(Session.t(), ExecutionRequest.t(), keyword()) ::
              {:ok, ProcessHandle.t()} | {:error, Error.t()}
  @callback list_processes(Session.t(), keyword()) ::
              {:ok, [ProcessStatus.t()]} | {:error, Error.t()}
  @callback process_status(Session.t(), ProcessHandle.t() | String.t(), keyword()) ::
              {:ok, ProcessStatus.t()} | {:error, Error.t()}
  @callback process_events(ProcessHandle.t(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t()}
  @callback write_process_stdin(ProcessHandle.t(), iodata(), keyword()) ::
              :ok | {:error, Error.t()}
  @callback close_process_stdin(ProcessHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback signal_process(ProcessHandle.t(), atom() | String.t(), keyword()) ::
              :ok | {:error, Error.t()}
  @callback kill_process(ProcessHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback wait_process(ProcessHandle.t(), keyword()) ::
              {:ok, ProcessStatus.t()} | {:error, Error.t()}
  @callback write_file(Session.t(), Path.t(), iodata(), keyword()) ::
              {:ok, FileRef.t()} | {:error, Error.t()}
  @callback read_file(Session.t(), Path.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  @callback list_files(Session.t(), Path.t(), keyword()) ::
              {:ok, [FileRef.t()]} | {:error, Error.t()}
  @callback delete_file(Session.t(), Path.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback checkpoint(Session.t(), keyword() | map(), keyword()) ::
              {:ok, LitterBox.Checkpoint.t()} | {:error, Error.t()}
  @callback restore(Session.t(), LitterBox.Checkpoint.t() | String.t(), keyword()) ::
              {:ok, Session.t()} | {:error, Error.t()}
  @callback start_service(Session.t(), keyword() | map(), keyword()) ::
              {:ok, LitterBox.Service.t()} | {:error, Error.t()}
  @callback stop_service(Session.t(), LitterBox.Service.t() | String.t(), keyword()) ::
              :ok | {:error, Error.t()}
  @callback list_services(Session.t(), keyword()) ::
              {:ok, [LitterBox.Service.t()]} | {:error, Error.t()}
  @callback open_proxy(Session.t(), LitterBox.Service.t() | String.t(), keyword()) ::
              {:ok, LitterBox.Proxy.t()} | {:error, Error.t()}
  @callback close_proxy(LitterBox.Proxy.t() | String.t(), keyword()) ::
              :ok | {:error, Error.t()}
  @callback acquire_lease(Session.t(), String.t(), keyword()) ::
              {:ok, LitterBox.Lease.t()} | {:error, Error.t()}
  @callback release_lease(LitterBox.Lease.t() | String.t(), keyword()) ::
              :ok | {:error, Error.t()}

  @optional_callbacks open_session: 2,
                      close_session: 2,
                      exec_session: 3,
                      attach_session: 3,
                      write_stdin: 3,
                      close_attach: 2,
                      start_process: 3,
                      list_processes: 2,
                      process_status: 3,
                      process_events: 2,
                      write_process_stdin: 3,
                      close_process_stdin: 2,
                      signal_process: 3,
                      kill_process: 2,
                      wait_process: 2,
                      write_file: 4,
                      read_file: 3,
                      list_files: 3,
                      delete_file: 3,
                      checkpoint: 3,
                      restore: 3,
                      start_service: 3,
                      stop_service: 3,
                      list_services: 2,
                      open_proxy: 3,
                      close_proxy: 2,
                      acquire_lease: 3,
                      release_lease: 2

  @spec open_session(module(), Profile.t(), keyword()) :: {:ok, Session.t()} | {:error, Error.t()}
  def open_session(module, %Profile{} = profile, opts) do
    Code.ensure_loaded?(module)

    if function_exported?(module, :open_session, 2) do
      module.open_session(profile, opts)
    else
      with {:ok, instance} <- module.provision(profile, opts) do
        Session.from_instance(instance,
          capabilities: session_capabilities(profile),
          policy: profile.policy,
          metadata: %{compatibility_mode: :one_shot_session}
        )
      end
    end
  end

  @spec close_session(module(), Session.t(), keyword()) :: :ok | {:error, Error.t()}
  def close_session(module, %Session{} = session, opts) do
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :close_session, 2) ->
        module.close_session(session, opts)

      match?(%Instance{}, session.instance) ->
        module.destroy(session.instance, opts)

      true ->
        :ok
    end
  end

  @spec exec_session(module(), Session.t(), ExecutionRequest.t(), keyword()) ::
          {:ok, ExecutionResult.t()} | {:error, Error.t()}
  def exec_session(module, %Session{} = session, %ExecutionRequest{} = request, opts) do
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :exec_session, 3) ->
        module.exec_session(session, request, opts)

      match?(%Instance{}, session.instance) and session.capabilities.exec? ->
        module.exec(session.instance, request, opts)

      true ->
        unsupported(:exec_session, session)
    end
  end

  @spec attach_session(module(), Session.t(), ExecutionRequest.t(), keyword()) ::
          {:ok, AttachHandle.t()} | {:error, Error.t()}
  def attach_session(module, %Session{} = session, %ExecutionRequest{} = request, opts) do
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :attach_session, 3) ->
        module.attach_session(session, request, opts)

      true ->
        unsupported(:attach_session, session)
    end
  end

  @spec write_stdin(module(), AttachHandle.t(), iodata(), keyword()) :: :ok | {:error, Error.t()}
  def write_stdin(module, %AttachHandle{} = handle, input, opts) do
    dispatch_or_unsupported(module, :write_stdin, [handle, input, opts], handle)
  end

  @spec close_attach(module(), AttachHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  def close_attach(module, %AttachHandle{} = handle, opts) do
    dispatch_or_unsupported(module, :close_attach, [handle, opts], handle)
  end

  @spec start_process(module(), Session.t(), ExecutionRequest.t(), keyword()) ::
          {:ok, ProcessHandle.t()} | {:error, Error.t()}
  def start_process(module, %Session{} = session, %ExecutionRequest{} = request, opts) do
    dispatch_or_unsupported(module, :start_process, [session, request, opts], session)
  end

  @spec list_processes(module(), Session.t(), keyword()) ::
          {:ok, [ProcessStatus.t()]} | {:error, Error.t()}
  def list_processes(module, %Session{} = session, opts) do
    dispatch_or_unsupported(module, :list_processes, [session, opts], session)
  end

  @spec process_status(module(), Session.t(), ProcessHandle.t() | String.t(), keyword()) ::
          {:ok, ProcessStatus.t()} | {:error, Error.t()}
  def process_status(module, %Session{} = session, process, opts) do
    dispatch_or_unsupported(module, :process_status, [session, process, opts], session)
  end

  @spec process_events(module(), ProcessHandle.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def process_events(module, %ProcessHandle{} = handle, opts) do
    Code.ensure_loaded?(module)

    if function_exported?(module, :process_events, 2) do
      module.process_events(handle, opts)
    else
      {:ok, ProcessHandle.events(handle)}
    end
  end

  @spec write_process_stdin(module(), ProcessHandle.t(), iodata(), keyword()) ::
          :ok | {:error, Error.t()}
  def write_process_stdin(module, %ProcessHandle{} = handle, input, opts) do
    dispatch_or_unsupported(module, :write_process_stdin, [handle, input, opts], handle)
  end

  @spec close_process_stdin(module(), ProcessHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  def close_process_stdin(module, %ProcessHandle{} = handle, opts) do
    dispatch_or_unsupported(module, :close_process_stdin, [handle, opts], handle)
  end

  @spec signal_process(module(), ProcessHandle.t(), atom() | String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def signal_process(module, %ProcessHandle{} = handle, signal, opts) do
    dispatch_or_unsupported(module, :signal_process, [handle, signal, opts], handle)
  end

  @spec kill_process(module(), ProcessHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  def kill_process(module, %ProcessHandle{} = handle, opts) do
    dispatch_or_unsupported(module, :kill_process, [handle, opts], handle)
  end

  @spec wait_process(module(), ProcessHandle.t(), keyword()) ::
          {:ok, ProcessStatus.t()} | {:error, Error.t()}
  def wait_process(module, %ProcessHandle{} = handle, opts) do
    dispatch_or_unsupported(module, :wait_process, [handle, opts], handle)
  end

  def write_file(module, session, path, contents, opts),
    do: dispatch_or_unsupported(module, :write_file, [session, path, contents, opts], session)

  def read_file(module, session, path, opts),
    do: dispatch_or_unsupported(module, :read_file, [session, path, opts], session)

  def list_files(module, session, path, opts),
    do: dispatch_or_unsupported(module, :list_files, [session, path, opts], session)

  def delete_file(module, session, path, opts),
    do: dispatch_or_unsupported(module, :delete_file, [session, path, opts], session)

  def checkpoint(module, session, spec, opts),
    do: dispatch_or_unsupported(module, :checkpoint, [session, spec, opts], session)

  def restore(module, session, checkpoint, opts),
    do: dispatch_or_unsupported(module, :restore, [session, checkpoint, opts], session)

  def start_service(module, session, spec, opts),
    do: dispatch_or_unsupported(module, :start_service, [session, spec, opts], session)

  def stop_service(module, session, service, opts),
    do: dispatch_or_unsupported(module, :stop_service, [session, service, opts], session)

  def list_services(module, session, opts),
    do: dispatch_or_unsupported(module, :list_services, [session, opts], session)

  def open_proxy(module, session, service, opts),
    do: dispatch_or_unsupported(module, :open_proxy, [session, service, opts], session)

  def close_proxy(module, proxy, opts),
    do: dispatch_or_unsupported(module, :close_proxy, [proxy, opts], proxy)

  def acquire_lease(module, session, resource, opts),
    do: dispatch_or_unsupported(module, :acquire_lease, [session, resource, opts], session)

  def release_lease(module, lease, opts),
    do: dispatch_or_unsupported(module, :release_lease, [lease, opts], lease)

  @spec unsupported(atom(), term()) :: {:error, Error.t()}
  def unsupported(operation, subject) do
    {backend, session_id} =
      case subject do
        %Session{} = session -> {session.backend, session.id}
        %{backend: backend} -> {backend, nil}
        _other -> {:unknown, nil}
      end

    {:error,
     Error.validation("sandbox backend does not support #{operation}",
       source: __MODULE__,
       details: %{operation: operation, backend: backend, session_id: session_id}
     )}
  end

  defp dispatch_or_unsupported(module, operation, args, subject) do
    Code.ensure_loaded?(module)

    if function_exported?(module, operation, length(args)) do
      apply(module, operation, args)
    else
      unsupported(operation, subject)
    end
  end

  defp session_capabilities(%Profile{} = profile) do
    LitterBox.Capabilities.one_shot_exec(
      network_policy?: true,
      persistent_identity?: profile.stateful? or profile.workspace.persist?
    )
  end
end
