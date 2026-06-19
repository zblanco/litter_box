defmodule LitterBox do
  @moduledoc """
  Sandbox execution facade.

  The contracts in this namespace keep inputs, outputs, diagnostics,
  artifacts, and policy as structured data while allowing different execution
  backends to be selected by profile.
  """

  alias LitterBox.Error
  alias LitterBox.AttachHandle
  alias LitterBox.Backend
  alias LitterBox.Backends.Docker
  alias LitterBox.Backends.JustBash
  alias LitterBox.Backends.Lua
  alias LitterBox.Backends.Remote
  alias LitterBox.Backends.Vmsan
  alias LitterBox.ExecutionRequest
  alias LitterBox.ExecutionResult
  alias LitterBox.Instance
  alias LitterBox.Manager
  alias LitterBox.Capabilities
  alias LitterBox.Policy
  alias LitterBox.ProcessHandle
  alias LitterBox.ProcessStatus
  alias LitterBox.Profile
  alias LitterBox.Session
  alias LitterBox.SessionRegistry

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Manager.start_link(opts)

  @spec exec(ExecutionRequest.t() | keyword() | map(), keyword()) ::
          {:ok, ExecutionResult.t()} | {:error, Error.t()}
  def exec(request_or_session, opts_or_request \\ [])

  def exec(%Session{} = session, request_input) do
    exec(session, request_input, [])
  end

  def exec(request_input, opts) do
    case Keyword.get(opts, :server) do
      nil ->
        direct_exec(request_input, opts)

      server ->
        Manager.exec(server, request_input)
    end
  end

  @spec exec(Session.t(), ExecutionRequest.t() | keyword() | map(), keyword()) ::
          {:ok, ExecutionResult.t()} | {:error, Error.t()}
  def exec(%Session{} = session, request_input, opts) do
    with :ok <- verify_session(session),
         :ok <- require_ready_session(session, :exec),
         {:ok, request} <- request_for_session(session, request_input),
         :ok <- authorize_session_request(session, request) do
      session.backend
      |> backend_module()
      |> Backend.exec_session(session, request, opts)
    end
  end

  @spec attach(Session.t(), ExecutionRequest.t() | keyword() | map(), keyword()) ::
          {:ok, AttachHandle.t()} | {:error, Error.t()}
  def attach(%Session{} = session, request_input, opts \\ []) do
    case Keyword.get(opts, :server) do
      nil ->
        with :ok <- verify_session(session),
             :ok <- require_ready_session(session, :attach),
             :ok <- require_streaming_session(session),
             {:ok, request} <- request_for_session(session, request_input),
             :ok <- authorize_session_request(session, request) do
          session.backend
          |> backend_module()
          |> Backend.attach_session(session, request, opts)
        end

      server ->
        Manager.attach(server, session, request_input, opts)
    end
  end

  @spec write_stdin(AttachHandle.t(), iodata(), keyword()) :: :ok | {:error, Error.t()}
  def write_stdin(%AttachHandle{} = handle, input, opts \\ []) do
    handle.backend
    |> backend_module()
    |> Backend.write_stdin(handle, input, opts)
  end

  @spec close_attach(AttachHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  def close_attach(%AttachHandle{} = handle, opts \\ []) do
    case Keyword.get(opts, :server) do
      nil ->
        handle.backend
        |> backend_module()
        |> Backend.close_attach(handle, opts)

      server ->
        Manager.close_attach(server, handle, opts)
    end
  end

  @spec start_process(Session.t(), ExecutionRequest.t() | keyword() | map(), keyword()) ::
          {:ok, ProcessHandle.t()} | {:error, Error.t()}
  def start_process(%Session{} = session, request_input, opts \\ []) do
    case Keyword.get(opts, :server) do
      nil ->
        with :ok <- verify_session(session),
             :ok <- require_ready_session(session, :start_process),
             :ok <- require_process_host_session(session),
             {:ok, request} <- request_for_session(session, request_input),
             :ok <- authorize_session_request(session, request) do
          session.backend
          |> backend_module()
          |> Backend.start_process(session, request, opts)
        end

      server ->
        Manager.start_process(server, session, request_input, opts)
    end
  end

  @spec list_processes(Session.t(), keyword()) :: {:ok, [ProcessStatus.t()]} | {:error, Error.t()}
  def list_processes(%Session{} = session, opts \\ []) do
    case Keyword.get(opts, :server) do
      nil ->
        with :ok <- verify_session(session),
             :ok <- require_ready_session(session, :list_processes),
             :ok <- require_process_host_session(session) do
          session.backend
          |> backend_module()
          |> Backend.list_processes(session, opts)
        end

      server ->
        Manager.list_processes(server, session, opts)
    end
  end

  @spec process_status(Session.t(), ProcessHandle.t() | String.t(), keyword()) ::
          {:ok, ProcessStatus.t()} | {:error, Error.t()}
  def process_status(%Session{} = session, process, opts \\ []) do
    case Keyword.get(opts, :server) do
      nil ->
        with :ok <- verify_session(session),
             :ok <- require_ready_session(session, :process_status),
             :ok <- require_process_host_session(session) do
          session.backend
          |> backend_module()
          |> Backend.process_status(session, process, opts)
        end

      server ->
        Manager.process_status(server, session, process, opts)
    end
  end

  @spec process_events(ProcessHandle.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def process_events(%ProcessHandle{} = handle, opts \\ []) do
    handle.backend
    |> backend_module()
    |> Backend.process_events(handle, opts)
  end

  @spec write_process_stdin(ProcessHandle.t(), iodata(), keyword()) :: :ok | {:error, Error.t()}
  def write_process_stdin(%ProcessHandle{} = handle, input, opts \\ []) do
    handle.backend
    |> backend_module()
    |> Backend.write_process_stdin(handle, input, opts)
  end

  @spec close_process_stdin(ProcessHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  def close_process_stdin(%ProcessHandle{} = handle, opts \\ []) do
    handle.backend
    |> backend_module()
    |> Backend.close_process_stdin(handle, opts)
  end

  @spec signal_process(ProcessHandle.t(), atom() | String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def signal_process(%ProcessHandle{} = handle, signal, opts \\ []) do
    handle.backend
    |> backend_module()
    |> Backend.signal_process(handle, signal, opts)
  end

  @spec kill_process(ProcessHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  def kill_process(%ProcessHandle{} = handle, opts \\ []) do
    case Keyword.get(opts, :server) do
      nil ->
        handle.backend
        |> backend_module()
        |> Backend.kill_process(handle, opts)

      server ->
        Manager.kill_process(server, handle, opts)
    end
  end

  @spec wait_process(ProcessHandle.t(), keyword()) ::
          {:ok, ProcessStatus.t()} | {:error, Error.t()}
  def wait_process(%ProcessHandle{} = handle, opts \\ []) do
    handle.backend
    |> backend_module()
    |> Backend.wait_process(handle, opts)
  end

  @spec status(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def status(opts \\ []) do
    case Keyword.get(opts, :server) do
      nil ->
        direct_status(opts)

      server ->
        Manager.status(server, Keyword.get(opts, :sandbox))
    end
  end

  @spec provision(Profile.t() | keyword() | map()) :: {:ok, Instance.t()} | {:error, Error.t()}
  def provision(%Profile{} = profile), do: backend_module(profile.backend).provision(profile, [])

  def provision(profile_input) do
    with {:ok, profile} <- Profile.new(profile_input) do
      provision(profile)
    end
  end

  @doc false
  @spec authorize_request(Profile.t(), ExecutionRequest.t()) :: :ok | {:error, Error.t()}
  def authorize_request(%Profile{} = profile, %ExecutionRequest{} = request) do
    with :ok <- authorize_enabled(profile),
         :ok <- authorize_runtime(profile, request),
         :ok <- authorize_network(profile, request),
         :ok <- authorize_restricted_egress(profile),
         :ok <- authorize_mcp_boundary(profile),
         :ok <- authorize_persistence(profile, request),
         :ok <- authorize_isolation(profile) do
      :ok
    end
  end

  @doc false
  @spec exec_with_instance(Instance.t(), ExecutionRequest.t(), keyword()) ::
          {:ok, ExecutionResult.t()} | {:error, Error.t()}
  def exec_with_instance(%Instance{} = instance, %ExecutionRequest{} = request, opts \\ []) do
    backend_module(instance.backend).exec(instance, request, opts)
  end

  @spec open_session(atom(), keyword() | map(), keyword()) ::
          {:ok, Session.t()} | {:error, Error.t()}
  def open_session(sandbox, spec \\ [], opts \\ []) when is_atom(sandbox) and is_list(opts) do
    case Keyword.get(opts, :server) do
      nil ->
        with {:ok, profile} <- profile_for_sandbox(sandbox, Keyword.get(opts, :profile, [])),
             :ok <- authorize_session_profile(profile),
             {:ok, session} <-
               profile.backend
               |> backend_module()
               |> Backend.open_session(profile, Keyword.merge(opts, spec: spec)) do
          {:ok, seal_session(session)}
        end

      server ->
        Manager.open_session(server, sandbox, spec)
    end
  end

  @spec acquire_session(atom(), keyword() | map(), keyword()) ::
          {:ok, Session.t()} | {:error, Error.t()}
  def acquire_session(sandbox, spec \\ [], opts \\ []) when is_atom(sandbox) and is_list(opts) do
    case Keyword.get(opts, :server) do
      nil -> open_session(sandbox, spec, opts)
      server -> Manager.acquire_session(server, sandbox, spec)
    end
  end

  @spec release_session(Session.t(), keyword()) :: :ok | {:error, Error.t()}
  def release_session(%Session{} = session, opts \\ []) do
    case Keyword.get(opts, :server) do
      nil -> close_session(session, opts)
      server -> Manager.release_session(server, session, opts)
    end
  end

  @spec reset_session(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, Error.t()}
  def reset_session(%Session{} = session, opts \\ []) do
    case Keyword.get(opts, :server) do
      nil ->
        with :ok <- verify_session(session),
             :ok <- require_ready_session(session, :reset_session),
             %Instance{} = instance <- session.instance,
             :ok <- reset(instance, opts) do
          {:ok, session}
        else
          nil ->
            {:error,
             Error.validation("sandbox session reset requires an instance",
               source: __MODULE__,
               details: %{session_id: session.id, backend: session.backend}
             )}

          {:error, error} ->
            {:error, error}
        end

      server ->
        Manager.reset_session(server, session, opts)
    end
  end

  @spec close_session(Session.t(), keyword()) :: :ok | {:error, Error.t()}
  def close_session(%Session{} = session, opts \\ []) do
    case Keyword.get(opts, :server) do
      nil ->
        with :ok <- verify_session(session) do
          with :ok <-
                 session.backend
                 |> backend_module()
                 |> Backend.close_session(session, opts) do
            revoke_session(session)
          end
        end

      server ->
        Manager.close_session(server, session, opts)
    end
  end

  @spec write_file(Session.t(), Path.t(), iodata(), keyword()) ::
          {:ok, LitterBox.FileRef.t()} | {:error, Error.t()}
  def write_file(%Session{} = session, path, contents, opts \\ []) do
    with :ok <- verify_session(session),
         :ok <- require_ready_session(session, :write_file) do
      session.backend
      |> backend_module()
      |> Backend.write_file(session, path, contents, opts)
    end
  end

  @spec read_file(Session.t(), Path.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def read_file(%Session{} = session, path, opts \\ []) do
    with :ok <- verify_session(session),
         :ok <- require_ready_session(session, :read_file) do
      session.backend
      |> backend_module()
      |> Backend.read_file(session, path, opts)
    end
  end

  @spec list_files(Session.t(), Path.t(), keyword()) ::
          {:ok, [LitterBox.FileRef.t()]} | {:error, Error.t()}
  def list_files(%Session{} = session, path \\ ".", opts \\ []) do
    with :ok <- verify_session(session),
         :ok <- require_ready_session(session, :list_files) do
      session.backend
      |> backend_module()
      |> Backend.list_files(session, path, opts)
    end
  end

  @spec delete_file(Session.t(), Path.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete_file(%Session{} = session, path, opts \\ []) do
    with :ok <- verify_session(session),
         :ok <- require_ready_session(session, :delete_file) do
      session.backend
      |> backend_module()
      |> Backend.delete_file(session, path, opts)
    end
  end

  @spec checkpoint(Session.t(), keyword() | map(), keyword()) ::
          {:ok, LitterBox.Checkpoint.t()} | {:error, Error.t()}
  def checkpoint(%Session{} = session, spec \\ [], opts \\ []) do
    with :ok <- verify_session(session),
         :ok <- require_ready_session(session, :checkpoint) do
      session.backend
      |> backend_module()
      |> Backend.checkpoint(session, spec, opts)
    end
  end

  @spec restore(Session.t(), LitterBox.Checkpoint.t() | String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, Error.t()}
  def restore(%Session{} = session, checkpoint, opts \\ []) do
    with :ok <- verify_session(session),
         :ok <- require_ready_session(session, :restore) do
      with {:ok, restored_session} <-
             session.backend
             |> backend_module()
             |> Backend.restore(session, checkpoint, opts) do
        {:ok, seal_session(restored_session)}
      end
    end
  end

  @spec start_service(Session.t(), keyword() | map(), keyword()) ::
          {:ok, LitterBox.Service.t()} | {:error, Error.t()}
  def start_service(%Session{} = session, spec, opts \\ []) do
    with :ok <- verify_session(session),
         :ok <- require_ready_session(session, :start_service) do
      session.backend
      |> backend_module()
      |> Backend.start_service(session, spec, opts)
    end
  end

  @spec stop_service(Session.t(), LitterBox.Service.t() | String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def stop_service(%Session{} = session, service, opts \\ []) do
    with :ok <- verify_session(session),
         :ok <- require_ready_session(session, :stop_service) do
      session.backend
      |> backend_module()
      |> Backend.stop_service(session, service, opts)
    end
  end

  @spec list_services(Session.t(), keyword()) ::
          {:ok, [LitterBox.Service.t()]} | {:error, Error.t()}
  def list_services(%Session{} = session, opts \\ []) do
    with :ok <- verify_session(session),
         :ok <- require_ready_session(session, :list_services) do
      session.backend
      |> backend_module()
      |> Backend.list_services(session, opts)
    end
  end

  @spec open_proxy(Session.t(), LitterBox.Service.t() | String.t(), keyword()) ::
          {:ok, LitterBox.Proxy.t()} | {:error, Error.t()}
  def open_proxy(%Session{} = session, service, opts \\ []) do
    with :ok <- verify_session(session),
         :ok <- require_ready_session(session, :open_proxy) do
      session.backend
      |> backend_module()
      |> Backend.open_proxy(session, service, opts)
    end
  end

  @spec close_proxy(LitterBox.Proxy.t() | String.t(), keyword()) :: :ok | {:error, Error.t()}
  def close_proxy(proxy, opts \\ [])

  def close_proxy(%LitterBox.Proxy{} = proxy, opts) do
    proxy.backend
    |> backend_module()
    |> Backend.close_proxy(proxy, opts)
  end

  def close_proxy(proxy, opts) do
    with {:ok, backend} <- backend_option(opts, :close_proxy) do
      backend
      |> backend_module()
      |> Backend.close_proxy(proxy, opts)
    end
  end

  @spec acquire_lease(Session.t(), String.t(), keyword()) ::
          {:ok, LitterBox.Lease.t()} | {:error, Error.t()}
  def acquire_lease(%Session{} = session, resource, opts \\ []) do
    case Keyword.get(opts, :server) do
      nil ->
        with :ok <- verify_session(session),
             :ok <- require_ready_session(session, :acquire_lease) do
          session.backend
          |> backend_module()
          |> Backend.acquire_lease(session, resource, opts)
        end

      server ->
        Manager.acquire_lease(server, session, resource, opts)
    end
  end

  @spec release_lease(LitterBox.Lease.t() | String.t(), keyword()) :: :ok | {:error, Error.t()}
  def release_lease(lease, opts \\ [])

  def release_lease(%LitterBox.Lease{} = lease, opts) do
    case Keyword.get(opts, :server) do
      nil ->
        lease.backend
        |> backend_module()
        |> Backend.release_lease(lease, opts)

      server ->
        Manager.release_lease(server, lease, opts)
    end
  end

  def release_lease(lease, opts) do
    with {:ok, backend} <- backend_option(opts, :release_lease) do
      backend
      |> backend_module()
      |> Backend.release_lease(lease, opts)
    end
  end

  @spec snapshot(Instance.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def snapshot(%Instance{} = instance, opts \\ []) do
    backend_module(instance.backend).snapshot(instance, opts)
  end

  @spec reset(Instance.t(), keyword()) :: :ok | {:error, Error.t()}
  def reset(%Instance{} = instance, opts \\ []) do
    backend_module(instance.backend).reset(instance, opts)
  end

  @spec destroy(Instance.t(), keyword()) :: :ok | {:error, Error.t()}
  def destroy(%Instance{} = instance, opts \\ []) do
    backend_module(instance.backend).destroy(instance, opts)
  end

  defp direct_exec(request_input, opts) do
    profile_input = Keyword.get(opts, :profile, [])

    with {:ok, request} <- ExecutionRequest.new(request_input),
         {:ok, profile} <- profile_for_request(request, profile_input),
         :ok <- authorize_request(profile, request) do
      direct_exec_with_profile(profile, request, opts)
    end
  end

  defp direct_exec_with_profile(%Profile{backend: :sprites} = profile, request, opts) do
    with {:ok, session} <-
           profile.backend
           |> backend_module()
           |> Backend.open_session(profile, Keyword.put_new(opts, :spec, [])) do
      session = seal_session(session)
      result = exec(session, request, opts)
      close_result = close_session(session, opts)

      case {result, close_result} do
        {{:ok, _result} = ok, :ok} -> ok
        {{:error, _error} = error, _close_result} -> error
        {{:ok, _result}, {:error, error}} -> {:error, error}
      end
    end
  end

  defp direct_exec_with_profile(%Profile{} = profile, request, opts) do
    with {:ok, instance} <- backend_module(profile.backend).provision(profile, opts),
         {:ok, result} <- exec_with_instance(instance, request, opts) do
      {:ok, result}
    end
  end

  defp direct_status(opts) do
    profile =
      opts
      |> Keyword.get(:profile, [])
      |> Profile.new!()

    with {:ok, health} <-
           backend_module(profile.backend).health(Keyword.put(opts, :profile, profile)) do
      {:ok,
       %{
         status: if(health.available?, do: :available, else: :unavailable),
         default_sandbox: profile.name,
         default_backend: profile.backend,
         backends: [health],
         profile: %{
           name: profile.name,
           backend: profile.backend,
           runtimes: profile.runtimes,
           isolation_level: profile.isolation_level,
           network: profile.policy.network,
           stateful?: profile.stateful?,
           workspace: profile.workspace,
           pool: profile.pool,
           metadata: profile.metadata
         }
       }}
    end
  end

  defp profile_for_request(%ExecutionRequest{} = request, []),
    do: Profile.new(name: request.sandbox)

  defp profile_for_request(%ExecutionRequest{}, %Profile{} = profile), do: {:ok, profile}

  defp profile_for_request(%ExecutionRequest{} = request, profile_input) do
    profile_input
    |> Map.new()
    |> Map.put_new(:name, request.sandbox)
    |> Profile.new()
  end

  defp profile_for_sandbox(sandbox, []), do: Profile.new(name: sandbox)
  defp profile_for_sandbox(_sandbox, %Profile{} = profile), do: {:ok, profile}

  defp profile_for_sandbox(sandbox, profile_input) do
    profile_input
    |> Map.new()
    |> Map.put_new(:name, sandbox)
    |> Profile.new()
  end

  defp authorize_enabled(%Profile{enabled?: true}), do: :ok

  defp authorize_enabled(%Profile{} = profile) do
    {:error,
     Error.validation("sandbox profile is disabled",
       source: __MODULE__,
       details: %{sandbox: profile.name}
     )}
  end

  defp authorize_session_profile(%Profile{} = profile) do
    with :ok <- authorize_enabled(profile),
         :ok <- authorize_restricted_egress(profile),
         :ok <- authorize_mcp_boundary(profile),
         :ok <- authorize_isolation(profile) do
      :ok
    end
  end

  defp authorize_runtime(%Profile{} = profile, %ExecutionRequest{} = request) do
    policy_runtimes = profile.policy.allowed_runtimes

    if request.runtime in profile.runtimes and
         (policy_runtimes == [] or request.runtime in policy_runtimes) do
      :ok
    else
      {:error,
       Error.validation("sandbox runtime is not enabled by profile",
         source: __MODULE__,
         details: %{runtime: request.runtime, enabled_runtimes: profile.runtimes}
       )}
    end
  end

  defp authorize_network(%Profile{policy: policy}, %ExecutionRequest{} = request) do
    cond do
      request.network == :disabled ->
        :ok

      policy.network == request.network ->
        :ok

      policy.network == :host ->
        :ok

      true ->
        {:error,
         Error.validation("sandbox network request exceeds profile policy",
           source: __MODULE__,
           details: %{requested_network: request.network, policy_network: policy.network}
         )}
    end
  end

  defp authorize_persistence(%Profile{} = profile, %ExecutionRequest{persist_changes?: true}) do
    if profile.policy.persist_changes? or profile.workspace.persist? or profile.stateful? do
      :ok
    else
      {:error,
       Error.validation("sandbox persistence request exceeds profile policy",
         source: __MODULE__,
         details: %{
           sandbox: profile.name,
           persist_changes?: true,
           policy_persist_changes?: profile.policy.persist_changes?,
           workspace_persist?: profile.workspace.persist?,
           stateful?: profile.stateful?
         }
       )}
    end
  end

  defp authorize_persistence(%Profile{}, %ExecutionRequest{}), do: :ok

  defp authorize_session_request(%Session{} = session, %ExecutionRequest{} = request) do
    with :ok <- authorize_session_exec(session),
         :ok <- authorize_session_isolation(session),
         :ok <- authorize_session_runtime(session, request),
         :ok <- authorize_session_network(session, request),
         :ok <- authorize_session_mcp_boundary(session, request),
         :ok <- authorize_session_persistence(session, request) do
      :ok
    end
  end

  defp authorize_session_exec(%Session{capabilities: %{exec?: true}}), do: :ok

  defp authorize_session_exec(%Session{} = session) do
    {:error,
     Error.validation("sandbox session does not support execution",
       source: __MODULE__,
       details: %{session_id: session.id, backend: session.backend}
     )}
  end

  defp require_streaming_session(%Session{capabilities: %{streaming?: true}}), do: :ok

  defp require_streaming_session(%Session{} = session) do
    {:error,
     Error.validation("sandbox session does not support streaming attach",
       source: __MODULE__,
       details: %{session_id: session.id, backend: session.backend}
     )}
  end

  defp require_process_host_session(%Session{} = session) do
    if Capabilities.process_host?(session.capabilities) do
      :ok
    else
      {:error,
       Error.validation("sandbox session does not support process hosting",
         source: __MODULE__,
         details: %{session_id: session.id, backend: session.backend}
       )}
    end
  end

  defp authorize_session_isolation(%Session{} = session) do
    if isolation_rank(session.isolation_level) >= isolation_rank(session.policy.isolation_minimum) do
      :ok
    else
      {:error,
       Error.validation("sandbox session isolation level is below policy",
         source: __MODULE__,
         details: %{
           session_id: session.id,
           isolation_level: session.isolation_level,
           isolation_minimum: session.policy.isolation_minimum
         }
       )}
    end
  end

  defp authorize_session_runtime(%Session{policy: policy}, %ExecutionRequest{} = request) do
    if policy.allowed_runtimes == [] or request.runtime in policy.allowed_runtimes do
      :ok
    else
      {:error,
       Error.validation("sandbox runtime is not enabled by session policy",
         source: __MODULE__,
         details: %{runtime: request.runtime, allowed_runtimes: policy.allowed_runtimes}
       )}
    end
  end

  defp authorize_session_network(%Session{policy: policy}, %ExecutionRequest{} = request) do
    cond do
      Policy.restricted_egress_requested?(policy) ->
        authorize_session_restricted_egress(policy, request)

      request.network == :disabled ->
        :ok

      policy.network == request.network ->
        :ok

      policy.network == :host ->
        :ok

      true ->
        {:error,
         Error.validation("sandbox network request exceeds session policy",
           source: __MODULE__,
           details: %{requested_network: request.network, policy_network: policy.network}
         )}
    end
  end

  defp authorize_session_restricted_egress(%Policy{} = _policy, %ExecutionRequest{
         network: :disabled
       }),
       do: :ok

  defp authorize_session_restricted_egress(%Policy{} = policy, %ExecutionRequest{} = request) do
    if request.network == policy.network do
      :ok
    else
      {:error,
       Error.validation("sandbox network request exceeds session policy",
         source: __MODULE__,
         details: %{requested_network: request.network, policy_network: policy.network}
       )}
    end
  end

  defp authorize_restricted_egress(%Profile{policy: policy} = profile) do
    if Policy.restricted_egress_requested?(policy) and
         not backend_restricted_egress_supported?(profile.backend) do
      restricted_egress_error(profile.backend, policy)
    else
      :ok
    end
  end

  defp backend_restricted_egress_supported?(backend) when backend in [:docker, :gvisor], do: true
  defp backend_restricted_egress_supported?(_backend), do: false

  defp restricted_egress_error(backend, policy) do
    {:error,
     Error.validation("sandbox restricted egress allow-list is not supported by backend",
       source: __MODULE__,
       details: %{
         backend: backend,
         policy: Policy.effective_network(policy),
         restricted_egress_supported?: false
       }
     )}
  end

  defp authorize_mcp_boundary(%Profile{policy: policy} = profile) do
    if Policy.mcp_boundary_requested?(policy) and
         not backend_mcp_boundary_supported?(profile.backend, policy) do
      mcp_boundary_error(profile.backend, policy)
    else
      :ok
    end
  end

  defp authorize_session_mcp_boundary(
         %Session{policy: policy} = session,
         %ExecutionRequest{} = request
       ) do
    cond do
      request.network == :disabled ->
        :ok

      not Policy.mcp_boundary_requested?(policy) ->
        :ok

      Capabilities.mcp_boundary_supported?(session.capabilities) and
          session_mcp_boundary_supported?(policy) ->
        :ok

      true ->
        {:error,
         Error.validation("sandbox MCP boundary is not supported by session",
           source: __MODULE__,
           details: %{
             session_id: session.id,
             backend: session.backend,
             requested_network: request.network,
             policy: Policy.effective_network(policy),
             mcp_boundary_supported?: false
           }
         )}
    end
  end

  defp backend_mcp_boundary_supported?(backend, policy) when backend in [:docker, :gvisor],
    do: session_mcp_boundary_supported?(policy)

  defp backend_mcp_boundary_supported?(_backend, _policy), do: false

  defp session_mcp_boundary_supported?(%Policy{} = policy) do
    case Policy.mcp_boundary(policy) do
      %{transport: "egress_allowlist"} -> Policy.restricted_egress_requested?(policy)
      _other -> false
    end
  end

  defp mcp_boundary_error(backend, policy) do
    {:error,
     Error.validation("sandbox MCP boundary is not supported by backend",
       source: __MODULE__,
       details: %{
         backend: backend,
         policy: Policy.effective_network(policy),
         mcp_boundary_supported?: false
       }
     )}
  end

  defp authorize_session_persistence(%Session{} = session, %ExecutionRequest{
         persist_changes?: true
       }) do
    if session.policy.persist_changes? or session.persistent_identity? do
      :ok
    else
      {:error,
       Error.validation("sandbox persistence request exceeds session policy",
         source: __MODULE__,
         details: %{session_id: session.id, backend: session.backend}
       )}
    end
  end

  defp authorize_session_persistence(%Session{}, %ExecutionRequest{}), do: :ok

  defp request_for_session(%Session{} = session, %ExecutionRequest{} = request) do
    request
    |> Map.from_struct()
    |> Map.put(:sandbox, session.sandbox)
    |> ExecutionRequest.new()
  end

  defp request_for_session(%Session{} = session, input) when is_map(input) do
    input
    |> Map.put_new(:sandbox, session.sandbox)
    |> put_session_default_cwd(session)
    |> ExecutionRequest.new()
  end

  defp request_for_session(%Session{} = session, input) when is_list(input) do
    input
    |> Keyword.put_new(:sandbox, session.sandbox)
    |> put_session_default_cwd(session)
    |> ExecutionRequest.new()
  end

  defp put_session_default_cwd(input, %Session{} = session) when is_map(input) do
    cond do
      Map.has_key?(input, :cwd) or Map.has_key?(input, "cwd") ->
        input

      Map.has_key?(input, :sandbox_cwd) or Map.has_key?(input, "sandbox_cwd") ->
        input

      default_cwd = session_default_cwd(session) ->
        Map.put(input, :cwd, default_cwd)

      true ->
        input
    end
  end

  defp put_session_default_cwd(input, %Session{} = session) when is_list(input) do
    cond do
      Keyword.has_key?(input, :cwd) or Keyword.has_key?(input, :sandbox_cwd) ->
        input

      default_cwd = session_default_cwd(session) ->
        Keyword.put(input, :cwd, default_cwd)

      true ->
        input
    end
  end

  defp session_default_cwd(%Session{} = session) do
    Map.get(session.metadata, :default_cwd) ||
      Map.get(session.metadata, "default_cwd") ||
      Capabilities.default_cwd(session.capabilities)
  end

  defp backend_option(opts, operation) do
    case Keyword.fetch(opts, :backend) do
      {:ok, backend} ->
        {:ok, backend}

      :error ->
        {:error,
         Error.validation("sandbox #{operation} requires a backend for opaque ids",
           source: __MODULE__,
           details: %{operation: operation}
         )}
    end
  end

  defp verify_session(%Session{} = session) do
    with :ok <- ensure_session_registry(),
         :ok <- verify_authority_signature(session),
         :ok <- registry_verify(session) do
      :ok
    end
  end

  defp seal_session(%Session{} = session) do
    :ok = ensure_session_registry()
    session = %{session | authority: nil}
    snapshot = authority_snapshot(session)
    signature = authority_signature(snapshot)
    :ok = GenServer.call(SessionRegistry, {:register, session.id, snapshot, signature})
    %{session | authority: %{version: 1, signature: signature}}
  end

  defp revoke_session(%Session{} = session) do
    :ok = ensure_session_registry()
    GenServer.call(SessionRegistry, {:revoke, session.id})
  end

  defp verify_authority_signature(
         %Session{authority: %{version: 1, signature: signature}} = session
       )
       when is_binary(signature) do
    snapshot = authority_snapshot(%{session | authority: nil})

    if secure_equal?(signature, authority_signature(snapshot)) do
      :ok
    else
      session_authority_error(
        session,
        "sandbox session authority snapshot does not match the handle"
      )
    end
  end

  defp verify_authority_signature(%Session{} = session),
    do: session_authority_error(session, "sandbox session authority is missing")

  defp registry_verify(%Session{} = session) do
    snapshot = authority_snapshot(%{session | authority: nil})
    signature = session.authority.signature

    case GenServer.call(SessionRegistry, {:verify, session.id, snapshot, signature}) do
      :ok ->
        :ok

      {:error, :unknown} ->
        session_authority_error(session, "sandbox session authority is not active")

      {:error, :mismatch} ->
        session_authority_error(
          session,
          "sandbox session authority registry does not match the handle"
        )
    end
  end

  defp authority_snapshot(%Session{} = session) do
    %{
      id: session.id,
      sandbox: session.sandbox,
      backend: session.backend,
      state: session.state,
      capabilities: Map.from_struct(session.capabilities),
      isolation_level: session.isolation_level,
      state_model: session.state_model,
      transport_model: session.transport_model,
      persistent_identity?: session.persistent_identity?,
      workspace_ref: session.workspace_ref,
      policy: Map.from_struct(session.policy),
      instance: instance_authority_snapshot(session.instance),
      metadata_hash:
        :sha256
        |> :crypto.hash(stable_term_binary(session.metadata))
        |> Base.encode16(case: :lower)
    }
  end

  defp instance_authority_snapshot(nil), do: nil

  defp instance_authority_snapshot(%Instance{} = instance) do
    %{
      id: instance.id,
      name: instance.name,
      backend: instance.backend,
      isolation_level: instance.isolation_level,
      state: instance.state,
      capabilities: instance.capabilities,
      workspace: Map.from_struct(instance.workspace),
      metadata_hash:
        :sha256
        |> :crypto.hash(stable_term_binary(instance.metadata))
        |> Base.encode16(case: :lower)
    }
  end

  defp authority_signature(snapshot) do
    :hmac
    |> :crypto.mac(:sha256, session_authority_secret(), stable_term_binary(snapshot))
    |> Base.encode16(case: :lower)
  end

  defp stable_term_binary(term), do: :erlang.term_to_binary(term, [:deterministic])

  defp session_authority_secret do
    key = {__MODULE__, :session_authority_secret}

    case :persistent_term.get(key, nil) do
      nil ->
        initialize_session_authority_secret(key)

      secret ->
        secret
    end
  end

  defp initialize_session_authority_secret(key) do
    lock = {key, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        case :persistent_term.get(key, nil) do
          nil ->
            secret = :crypto.strong_rand_bytes(32)
            :persistent_term.put(key, secret)
            secret

          secret ->
            secret
        end
      after
        :global.del_lock(lock, [node()])
      end
    else
      Process.sleep(1)
      session_authority_secret()
    end
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp ensure_session_registry do
    case Process.whereis(SessionRegistry) do
      nil ->
        case SessionRegistry.start([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, Error.from_reason(reason, source: __MODULE__)}
        end

      _pid ->
        :ok
    end
  end

  defp session_authority_error(%Session{} = session, message) do
    {:error,
     Error.validation(message,
       source: __MODULE__,
       details: %{session_id: session.id, backend: session.backend}
     )}
  end

  defp require_ready_session(%Session{state: :ready}, _operation), do: :ok

  defp require_ready_session(%Session{} = session, operation) do
    {:error,
     Error.validation("sandbox session is not ready",
       source: __MODULE__,
       details: %{
         operation: operation,
         session_id: session.id,
         backend: session.backend,
         state: session.state
       }
     )}
  end

  defp authorize_isolation(%Profile{} = profile) do
    if isolation_rank(profile.isolation_level) >= isolation_rank(profile.policy.isolation_minimum) do
      :ok
    else
      {:error,
       Error.validation("sandbox isolation level is below profile policy",
         source: __MODULE__,
         details: %{
           isolation_level: profile.isolation_level,
           isolation_minimum: profile.policy.isolation_minimum
         }
       )}
    end
  end

  defp isolation_rank(:in_process), do: 0
  defp isolation_rank(:in_process_virtual), do: 1
  defp isolation_rank(:wasi), do: 2
  defp isolation_rank(:namespace), do: 3
  defp isolation_rank(:container), do: 4
  defp isolation_rank(:gvisor), do: 5
  defp isolation_rank(:microvm), do: 6
  defp isolation_rank(:remote_microvm), do: 6
  defp isolation_rank(_other), do: -1

  defp backend_module(:just_bash), do: JustBash
  defp backend_module(:lua), do: Lua
  defp backend_module(:docker), do: Docker
  defp backend_module(:gvisor), do: Docker
  defp backend_module(:vmsan), do: Vmsan
  defp backend_module(:sprites), do: LitterBox.Backends.Sprites
  defp backend_module(:remote), do: Remote

  defp backend_module(backend) do
    raise ArgumentError, "unsupported sandbox backend: #{inspect(backend)}"
  end
end
