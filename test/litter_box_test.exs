defmodule LitterBoxTest do
  use ExUnit.Case, async: false

  alias LitterBox.Backend
  alias LitterBox.AttachBridge
  alias LitterBox.AttachHandle
  alias LitterBox.Capabilities
  alias LitterBox.Checkpoint
  alias LitterBox.ConsumerProfiles
  alias LitterBox.ExecutionRequest
  alias LitterBox.ExecutionResult
  alias LitterBox.FileRef
  alias LitterBox.HostProbe
  alias LitterBox.Lease
  alias LitterBox.ProcessHandle
  alias LitterBox.ProcessStatus
  alias LitterBox.Profile
  alias LitterBox.Proxy
  alias LitterBox.Service
  alias LitterBox.Session
  alias LitterBox.SessionEvent
  alias LitterBox.Test.FakeBackend
  alias LitterBox.Test.FakeDocker
  alias LitterBox.Test.NoAttachBackend
  alias LitterBox.VmsanCLI

  test "validates request and result contracts" do
    assert {:ok, request} =
             ExecutionRequest.new(
               sandbox: :local_code,
               runtime: "bash",
               source: "echo contract",
               network: %{enabled: false}
             )

    assert request.runtime == :bash
    assert request.network == :disabled

    assert {:error, error} =
             ExecutionResult.new(
               status: :pass,
               stdout: "",
               stderr: "",
               backend: :just_bash,
               isolation_level: nil
             )

    assert error.message =~ "isolation_level"
  end

  test "profile normalizes extended pool lifecycle options" do
    assert {:ok, profile} =
             Profile.new(
               name: :local_code,
               backend: :just_bash,
               pool: [
                 warm: 1,
                 max: 3,
                 idle_ttl_ms: 5_000,
                 checkout_timeout_ms: 25,
                 reset_on_checkin?: true,
                 checkpoint_on_checkout?: true,
                 backend_affinity: :backend
               ]
             )

    assert profile.pool == %{
             warm: 1,
             max: 3,
             idle_ttl_ms: 5_000,
             checkout_timeout_ms: 25,
             reset_on_checkin?: true,
             checkpoint_on_checkout?: true,
             backend_affinity: :backend
           }

    assert {:error, error} = Profile.new(name: :local_code, pool: [warm: 2, max: 1])
    assert error.message == "sandbox pool must include non-negative warm and positive max"
  end

  test "profile normalizes scalar runtime strings" do
    assert {:ok, profile} = Profile.new(name: :local_code, runtimes: "python")
    assert profile.runtimes == [:python]
    assert profile.policy.allowed_runtimes == [:python]

    assert {:ok, profile} = Profile.new(name: :local_code, runtimes: "python,node")
    assert profile.runtimes == [:python, :node]
    assert profile.policy.allowed_runtimes == [:python, :node]
  end

  test "supervised facade executes through configured sandbox profile" do
    name = :"litter_box_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           pool: [warm: 0, max: 1],
           network: :disabled,
           workspace: [mode: :copy_in, persist?: false]
         ]
       ]}
    )

    assert {:ok, status} = LitterBox.status(server: name)
    assert status.sandboxes.local_code.backend == :just_bash

    assert {:ok, result} =
             LitterBox.exec(
               %{
                 sandbox: :local_code,
                 runtime: :bash,
                 source: "echo package-sandbox"
               },
               server: name
             )

    assert result.status == :pass
    assert result.stdout == "package-sandbox\n"
    assert result.backend == :just_bash
    refute result.metadata.security_boundary?

    assert {:ok, instance} = LitterBox.provision(backend: :just_bash)
    assert {:ok, snapshot} = LitterBox.snapshot(instance)
    assert snapshot.backend == :just_bash
    assert :ok = LitterBox.reset(instance)
    assert :ok = LitterBox.destroy(instance)
  end

  test "supervised facade opens sessions through configured sandbox profiles" do
    name = :"litter_box_session_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           network: :disabled,
           workspace: [mode: :copy_in, persist?: false]
         ]
       ]}
    )

    assert {:ok, session} = LitterBox.open_session(:local_code, [], server: name)
    assert session.backend == :just_bash
    assert session.capabilities.exec?

    assert {:ok, result} =
             LitterBox.exec(session, runtime: :bash, source: "echo supervised-session")

    assert result.stdout == "supervised-session\n"

    assert {:error, error} = LitterBox.open_session(:missing, [], server: name)
    assert error.message == "unknown sandbox profile"
  end

  test "manager acquires, releases, and enforces pooled session limits" do
    name = :"litter_box_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           pool: [
             warm: 1,
             max: 2,
             idle_ttl_ms: :infinity,
             checkout_timeout_ms: 0
           ],
           network: :disabled
         ]
       ]}
    )

    assert {:ok, status} = LitterBox.status(server: name)
    assert [%{lifecycle: :idle} = warm] = status.sandboxes.local_code.sessions
    assert status.sandboxes.local_code.pool_status.ready == 1
    assert warm.readiness == :ready

    assert {:ok, first} = LitterBox.acquire_session(:local_code, [], server: name)
    assert first.id == warm.id

    assert {:ok, status} = LitterBox.status(server: name)
    assert status.sandboxes.local_code.pool_status.busy == 1

    assert [%{checkout_source: :warm, last_checkout_latency_ms: warm_latency}] =
             status.sandboxes.local_code.sessions

    assert is_integer(warm_latency)
    assert warm_latency >= 0

    assert {:ok, lease} = LitterBox.acquire_lease(first, "workspace", server: name)
    assert lease.resource == "workspace"

    assert {:error, error} = LitterBox.acquire_lease(first, "workspace", server: name)
    assert error.message == "sandbox lease conflicts with an active lease"
    assert error.retryable?

    assert {:error, error} = LitterBox.release_session(first, server: name)
    assert error.message == "sandbox session has active leases"

    assert :ok = LitterBox.release_lease(lease, server: name)

    assert {:ok, second} = LitterBox.acquire_session(:local_code, [], server: name)
    refute second.id == first.id

    assert {:ok, status} = LitterBox.status(server: name)
    assert status.sandboxes.local_code.pool_status.busy == 2
    assert Enum.any?(status.sandboxes.local_code.sessions, &(&1.checkout_source == :cold))

    assert {:error, error} = LitterBox.acquire_session(:local_code, [], server: name)
    assert error.message == "sandbox session pool is exhausted"
    assert error.retryable?
    assert error.details.max == 2

    assert :ok = LitterBox.release_session(first, server: name)
    assert {:ok, reacquired} = LitterBox.acquire_session(:local_code, [], server: name)
    assert reacquired.id == first.id

    assert :ok = LitterBox.release_session(reacquired, server: name)
    assert :ok = LitterBox.release_session(second, server: name)
  end

  test "manager records checkpoint-on-checkout policy evidence" do
    name = :"litter_box_checkpoint_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           pool: [warm: 1, max: 1, checkpoint_on_checkout?: true],
           network: :disabled
         ]
       ]}
    )

    assert {:ok, session} = LitterBox.acquire_session(:local_code, [], server: name)
    assert {:ok, status} = LitterBox.status(server: name)
    assert [%{checkout_checkpoint: checkpoint}] = status.sandboxes.local_code.sessions
    assert checkpoint.status == :skipped
    assert checkpoint.reason == :unsupported

    assert :ok = LitterBox.release_session(session, server: name)
  end

  test "managed open_session respects pool max and close_session removes entries" do
    name = :"litter_box_open_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           pool: [warm: 0, max: 1],
           network: :disabled
         ]
       ]}
    )

    assert {:ok, session} = LitterBox.open_session(:local_code, [], server: name)

    assert {:error, error} = LitterBox.open_session(:local_code, [], server: name)
    assert error.message == "sandbox session pool is exhausted"

    assert :ok = LitterBox.close_session(session, server: name)
    assert {:ok, status} = LitterBox.status(server: name)
    assert status.sandboxes.local_code.sessions == []

    assert {:ok, reopened} = LitterBox.open_session(:local_code, [], server: name)
    assert reopened.id != session.id
    assert :ok = LitterBox.close_session(reopened, server: name)
  end

  test "managed attach lifecycle blocks release until the attach stream terminates" do
    name = :"litter_box_attach_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           pool: [warm: 0, max: 1],
           network: :disabled
         ]
       ]}
    )

    assert {:ok, session} = LitterBox.acquire_session(:local_code, [], server: name)

    assert {:ok, handle} =
             LitterBox.attach(
               session,
               [runtime: :bash, source: "echo managed-attach"],
               server: name
             )

    assert handle.status == :closed

    assert {:ok, status} = LitterBox.status(server: name)
    assert [tracked] = status.sandboxes.local_code.sessions
    assert tracked.active_attach_count == 1
    assert [%{id: attach_id, session_id: session_id}] = tracked.active_attaches
    assert attach_id == handle.id
    assert session_id == session.id

    assert {:error, error} = LitterBox.release_session(session, server: name)
    assert error.message == "sandbox session has active attaches"
    assert error.details.attach_ids == [handle.id]

    assert {:ok, status} = LitterBox.status(server: name)

    assert [%{lifecycle: :checked_out, active_attach_count: 1}] =
             status.sandboxes.local_code.sessions

    assert attach_stdout(handle) == "managed-attach\n"

    assert {:ok, status} = LitterBox.status(server: name)
    assert [%{active_attach_count: 0, active_attaches: []}] = status.sandboxes.local_code.sessions

    assert :ok = LitterBox.close_attach(handle, server: name)
    assert :ok = LitterBox.close_attach(handle, server: name)

    assert :ok = LitterBox.release_session(session, server: name)
  end

  test "managed close_session cleans active attaches and frees pool capacity" do
    name = :"litter_box_attach_close_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           pool: [warm: 0, max: 1],
           network: :disabled
         ]
       ]}
    )

    assert {:ok, session} = LitterBox.acquire_session(:local_code, [], server: name)

    assert {:ok, handle} =
             LitterBox.attach(
               session,
               [runtime: :bash, source: "echo close-cleans-attach"],
               server: name
             )

    assert {:ok, status} = LitterBox.status(server: name)
    assert [%{active_attach_count: 1}] = status.sandboxes.local_code.sessions

    assert :ok = LitterBox.close_session(session, server: name)

    assert {:ok, status} = LitterBox.status(server: name)
    assert status.sandboxes.local_code.sessions == []
    assert attach_stdout(handle) == "close-cleans-attach\n"

    assert {:ok, reopened} = LitterBox.acquire_session(:local_code, [], server: name)
    assert reopened.id != session.id
    assert :ok = LitterBox.close_session(reopened, server: name)
  end

  test "manager can reset sessions on checkin and reap expired idle sessions" do
    reset_name = :"litter_box_reset_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: reset_name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           pool: [warm: 0, max: 1, reset_on_checkin?: true],
           network: :disabled
         ]
       ]}
    )

    assert {:ok, session} = LitterBox.acquire_session(:local_code, [], server: reset_name)
    assert :ok = LitterBox.release_session(session, server: reset_name)
    assert {:ok, status} = LitterBox.status(server: reset_name)
    assert [%{lifecycle: :idle} = reset] = status.sandboxes.local_code.sessions
    refute reset.id == session.id

    reap_name = :"litter_box_reap_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: reap_name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           pool: [warm: 0, max: 1, idle_ttl_ms: 0],
           network: :disabled
         ]
       ]}
    )

    assert {:ok, session} = LitterBox.acquire_session(:local_code, [], server: reap_name)
    assert :ok = LitterBox.release_session(session, server: reap_name)
    assert {:ok, status} = LitterBox.status(server: reap_name)
    assert status.sandboxes.local_code.sessions == []

    stale_name = :"litter_box_stale_warm_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: stale_name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           pool: [warm: 1, max: 1, idle_ttl_ms: 0],
           network: :disabled
         ]
       ]}
    )

    assert {:ok, status} = LitterBox.status(server: stale_name)
    assert status.sandboxes.local_code.pool_status.stale == 1
    assert [%{readiness: :stale}] = status.sandboxes.local_code.sessions

    reaper_name = :"litter_box_reaper_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: reaper_name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           pool: [warm: 0, max: 1, idle_ttl_ms: 10],
           network: :disabled
         ]
       ]}
    )

    assert {:ok, session} = LitterBox.acquire_session(:local_code, [], server: reaper_name)
    assert :ok = LitterBox.release_session(session, server: reaper_name)
    assert map_size(:sys.get_state(reaper_name).sessions) == 1
    assert wait_until(fn -> :sys.get_state(reaper_name).sessions == %{} end)
  end

  test "execution-role pool resets on checkin instead of reusing unsafe state" do
    name = :"litter_box_execution_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: name,
       sandboxes: [
         execution: [
           backend: :just_bash,
           runtimes: [:bash],
           metadata: %{role: :execution},
           pool: [warm: 0, max: 1, reset_on_checkin?: true],
           network: :disabled
         ]
       ]}
    )

    assert {:ok, first} = LitterBox.acquire_session(:execution, [], server: name)
    assert :ok = LitterBox.release_session(first, server: name)
    assert {:ok, status} = LitterBox.status(server: name)
    assert status.sandboxes.execution.metadata.role == :execution
    assert [%{lifecycle: :idle, readiness: :ready} = reset] = status.sandboxes.execution.sessions
    refute reset.id == first.id

    assert {:ok, second} = LitterBox.acquire_session(:execution, [], server: name)
    assert second.id == reset.id
    refute second.id == first.id
    assert :ok = LitterBox.release_session(second, server: name)
  end

  test "manager monitors checked-out session owners and frees abandoned capacity" do
    name = :"litter_box_owner_pool_#{System.unique_integer([:positive])}"
    parent = self()

    start_supervised!(
      {LitterBox,
       name: name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           pool: [warm: 0, max: 1],
           network: :disabled
         ]
       ]}
    )

    owner =
      spawn(fn ->
        {:ok, session} = LitterBox.acquire_session(:local_code, [], server: name)
        send(parent, {:checked_out, session.id})
      end)

    assert_receive {:checked_out, session_id}
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}

    assert wait_until(fn -> :sys.get_state(name).sessions == %{} end)
    assert {:ok, session} = LitterBox.acquire_session(:local_code, [], server: name)
    refute session.id == session_id
    assert :ok = LitterBox.close_session(session, server: name)
  end

  test "libbit workspace consumer profile is package-level and provider neutral" do
    assert {:libbit_workspace, config} =
             ConsumerProfiles.libbit_workspace(
               workspace_id: "Acme Workspace 42",
               tenant_id: "tenant-1",
               workflow_run_id: "workflow-run-9",
               agent_id: "agent-7",
               backend: :sprites,
               organization: "acme",
               warm: 1,
               max: 3
             )

    assert {:ok, profile} = Profile.from_named_config(:libbit_workspace, config)
    assert profile.backend == :sprites
    assert profile.stateful?
    assert profile.workspace.persist?
    assert profile.workspace.metadata.workspace_id == "Acme Workspace 42"
    assert profile.pool.checkpoint_on_checkout?
    assert profile.metadata.consumer == :libbit
    assert profile.metadata.tenant_id == "tenant-1"
    assert profile.metadata.workflow_run_id == "workflow-run-9"
    assert profile.backend_options.sprite =~ ~r/^libbit-acme-workspace-42-[0-9a-f]{12}$/
    assert profile.backend_options.organization == "acme"
    assert profile.backend_options.token_env == "SPRITES_TOKEN"

    sprites =
      ["a/b", "a b", "a_b"]
      |> Enum.map(fn workspace_id ->
        {_name, config} =
          ConsumerProfiles.libbit_workspace(workspace_id: workspace_id, tenant_id: "tenant-1")

        config[:backend_options].sprite
      end)

    assert Enum.uniq(sprites) == sprites
  end

  test "agent CLI consumer profiles keep model credentials behind host proxies" do
    assert {:agent_cli_dev, dev_config} =
             ConsumerProfiles.agent_cli_dev(mcp_port: 4000, model_proxy_port: 4100)

    assert {:agent_cli_execution, execution_config} =
             ConsumerProfiles.agent_cli_execution(mcp_port: 4000, model_proxy_port: 4100)

    assert [{:agent_cli_dev, pair_dev_config}, {:agent_cli_execution, pair_execution_config}] =
             ConsumerProfiles.agent_cli_pair(
               mcp_port: 5000,
               execution: [model_proxy_port: 5100]
             )

    assert {:ok, dev_profile} = Profile.from_named_config(:agent_cli_dev, dev_config)

    assert {:ok, execution_profile} =
             Profile.from_named_config(:agent_cli_execution, execution_config)

    assert {:ok, pair_dev_profile} = Profile.from_named_config(:agent_cli_dev, pair_dev_config)

    assert {:ok, pair_execution_profile} =
             Profile.from_named_config(:agent_cli_execution, pair_execution_config)

    assert dev_profile.backend == :docker
    assert dev_profile.stateful?
    assert dev_profile.workspace.persist?
    assert dev_profile.pool.warm == 1
    assert dev_profile.pool.max == 2
    assert dev_profile.pool.checkpoint_on_checkout?
    refute dev_profile.pool.reset_on_checkin?

    assert execution_profile.pool.max == 4
    assert execution_profile.pool.reset_on_checkin?
    refute execution_profile.pool.checkpoint_on_checkout?

    assert dev_profile.backend_options.image == "runic-ai/sandbox-agent-cli:latest"

    assert dev_profile.backend_options.environment == %{
             "RUNIC_MCP_URL" => "http://host.docker.internal:4000",
             "RUNIC_MODEL_PROXY_URL" => "http://host.docker.internal:4100"
           }

    assert pair_dev_profile.backend_options.environment["RUNIC_MCP_URL"] ==
             "http://host.docker.internal:5000"

    assert pair_execution_profile.backend_options.environment["RUNIC_MODEL_PROXY_URL"] ==
             "http://host.docker.internal:5100"

    refute Map.has_key?(dev_profile.backend_options.environment, "ANTHROPIC_API_KEY")
    refute Map.has_key?(dev_profile.backend_options.environment, "OPENAI_API_KEY")

    assert LitterBox.Policy.egress_allowlist(dev_profile.policy) == [
             %{scheme: "http", host: "host.docker.internal", port: 4000, purpose: "mcp"},
             %{scheme: "http", host: "host.docker.internal", port: 4100, purpose: "model"}
           ]

    assert LitterBox.Policy.mcp_boundary(dev_profile.policy) == %{
             transport: "egress_allowlist",
             purpose: "mcp"
           }

    refute dev_profile.policy.metadata.internet_egress?
    assert dev_profile.metadata.credential_boundary == :host_proxy
    assert dev_profile.metadata.agent_home == "/opt/runic-ai/agents"
  end

  test "libbit-like workspace isolation contract uses sandbox primitives only" do
    workspace_id = "workspace-123"
    workflow_run_id = "workflow-run-123"
    agent_id = "agent-abc"

    assert {_name, config} =
             ConsumerProfiles.libbit_workspace(
               workspace_id: workspace_id,
               workflow_run_id: workflow_run_id,
               agent_id: agent_id,
               backend: :docker,
               max: 1
             )

    assert {:ok, profile} = Profile.from_named_config(:libbit_workspace, config)
    assert {:ok, session} = Backend.open_session(FakeBackend, profile, [])

    assert session.policy.persist_changes?
    assert session.capabilities.checkpoints?
    assert session.capabilities.services?
    assert session.capabilities.proxy?

    assert {:ok, lease} =
             Backend.acquire_lease(FakeBackend, session, "workspace:#{workspace_id}", [])

    assert lease.mode == :exclusive

    checkpoint_spec = [
      reason: :before_risky_action,
      workflow_run_id: workflow_run_id
    ]

    assert {:ok, checkpoint} = Backend.checkpoint(FakeBackend, session, checkpoint_spec, [])

    assert checkpoint.session_id == session.id
    assert Checkpoint.kind(checkpoint) == :microvm_snapshot
    assert Checkpoint.preserves?(checkpoint, :process_memory)

    assert {:ok, result} =
             Backend.exec_session(
               FakeBackend,
               session,
               ExecutionRequest.new!(
                 sandbox: :libbit_workspace,
                 runtime: :bash,
                 source: "echo workflow #{workflow_run_id} agent #{agent_id}"
               ),
               []
             )

    assert result.status == :pass
    assert result.stdout =~ workflow_run_id
    assert result.stdout =~ agent_id

    assert {:ok, artifact} =
             Backend.write_file(
               FakeBackend,
               session,
               "/workspace/artifacts/result.json",
               ~s({"ok":true}),
               []
             )

    assert artifact.path == "/workspace/artifacts/result.json"

    assert {:ok, [%FileRef{}]} =
             Backend.list_files(FakeBackend, session, "/workspace/artifacts", [])

    assert {:ok, restored} = Backend.restore(FakeBackend, session, checkpoint, [])
    assert restored.id == session.id

    assert {:ok, service} = Backend.start_service(FakeBackend, session, [name: "forms"], [])
    assert {:ok, proxy} = Backend.open_proxy(FakeBackend, session, service, [])
    assert proxy.service_id == service.id

    assert :ok = Backend.close_proxy(FakeBackend, proxy, [])
    assert :ok = Backend.release_lease(FakeBackend, lease, [])
    assert :ok = Backend.close_session(FakeBackend, session, [])
  end

  test "supervised facade authorizes requests before backend execution" do
    name = :"litter_box_policy_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LitterBox,
       name: name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           runtimes: [:bash],
           network: :disabled,
           workspace: [mode: :copy_in, persist?: false]
         ]
       ]}
    )

    assert {:error, error} =
             LitterBox.exec(
               %{sandbox: :local_code, runtime: :python, source: "print('blocked')"},
               server: name
             )

    assert error.message == "sandbox runtime is not enabled by profile"
    assert error.details.runtime == :python

    assert {:error, error} =
             LitterBox.exec(
               %{sandbox: :local_code, runtime: :bash, source: "echo blocked", network: :host},
               server: name
             )

    assert error.message == "sandbox network request exceeds profile policy"
    assert error.details.requested_network == :host

    assert {:error, error} =
             LitterBox.exec(
               %{
                 sandbox: :local_code,
                 runtime: :bash,
                 source: "echo blocked",
                 persist_changes?: true
               },
               server: name
             )

    assert error.message == "sandbox persistence request exceeds profile policy"
  end

  test "contract normalization does not create atoms from unknown strings" do
    unknown_runtime = "runic_unknown_runtime_#{System.unique_integer([:positive])}"
    unknown_sandbox = "runic_unknown_sandbox_#{System.unique_integer([:positive])}"

    assert {:error, error} =
             ExecutionRequest.new(
               sandbox: unknown_sandbox,
               runtime: "bash",
               source: "echo blocked"
             )

    assert error.message =~ "sandbox"

    assert {:error, error} =
             ExecutionRequest.new(runtime: unknown_runtime, source: "echo blocked")

    assert error.message =~ "runtime"

    assert {:error, error} =
             Profile.new(name: unknown_sandbox, backend: "not_a_backend")

    assert error.message =~ "profile name"

    assert {:error, error} = LitterBox.Policy.new(allowed_runtimes: [unknown_runtime])
    assert error.message =~ "known atom string"

    assert {:ok, policy} =
             LitterBox.Policy.new(
               network: :restricted,
               metadata: %{
                 egress_allowlist: [
                   %{scheme: "HTTP", host: "127.0.0.1", port: "4567", purpose: :mcp}
                 ]
               }
             )

    assert policy.network == :restricted
    assert policy.metadata.deny_by_default?

    assert LitterBox.Policy.egress_allowlist(policy) == [
             %{scheme: "http", host: "127.0.0.1", port: 4567, purpose: "mcp"}
           ]

    assert LitterBox.Policy.restricted_egress_requested?(policy)

    assert LitterBox.Policy.effective_network(policy) == %{
             mode: :restricted,
             deny_by_default?: true,
             restricted_egress?: true,
             mcp_boundary: nil,
             egress_allowlist: [
               %{scheme: "http", host: "127.0.0.1", port: 4567, purpose: "mcp"}
             ]
           }

    assert {:ok, deny_all} = LitterBox.Policy.new(network: :restricted)
    assert deny_all.metadata.deny_by_default?
    assert deny_all.metadata.egress_allowlist == []
    refute LitterBox.Policy.restricted_egress_requested?(deny_all)

    assert {:error, error} =
             LitterBox.Policy.new(
               network: :host,
               metadata: %{egress_allowlist: [%{scheme: "https", host: "hex.pm", port: 443}]}
             )

    assert error.message == "sandbox egress_allowlist requires restricted networking"

    assert {:ok, mcp_policy} =
             LitterBox.Policy.new(
               network: :restricted,
               metadata: %{
                 mcp_boundary: %{transport: :host_forward, host: "127.0.0.1", port: "4567"}
               }
             )

    assert LitterBox.Policy.mcp_boundary_requested?(mcp_policy)

    assert LitterBox.Policy.mcp_boundary(mcp_policy) == %{
             transport: "host_forward",
             host: "127.0.0.1",
             port: 4567
           }

    assert {:ok, socket_policy} =
             LitterBox.Policy.new(
               network: :restricted,
               mcp_boundary: %{transport: "unix_socket", path: "/tmp/runic-mcp.sock"}
             )

    assert LitterBox.Policy.mcp_boundary(socket_policy) == %{
             transport: "unix_socket",
             path: "/tmp/runic-mcp.sock"
           }

    assert {:error, error} =
             LitterBox.Policy.new(
               network: :restricted,
               mcp_boundary: %{transport: :egress_allowlist}
             )

    assert error.message == "sandbox MCP egress_allowlist boundary requires restricted egress"

    assert {:ok, profile} =
             Profile.new(name: :local_code, backend: "docker", isolation_level: "container")

    assert profile.backend == :docker
    assert profile.isolation_level == :container

    assert {:error, error} =
             ExecutionResult.new(
               status: "made_up_status",
               stdout: "",
               stderr: "",
               backend: :just_bash,
               isolation_level: :in_process_virtual
             )

    assert error.message =~ "status"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_runtime) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_sandbox) end
  end

  test "session contract structs validate provider-neutral metadata" do
    assert {:ok, capabilities} =
             Capabilities.new(
               exec?: true,
               files?: true,
               checkpoints?: false,
               services?: false,
               proxy?: false,
               leases?: true,
               streaming?: true,
               network_policy?: true,
               persistent_identity?: true,
               metadata:
                 Capabilities.attach_metadata(:live_stream,
                   stdin_supported?: true,
                   stdin_close_supported?: true,
                   stderr_separate?: true,
                   state_tier: :persistent_process_host,
                   process_host?: true,
                   workspace_persistent?: true,
                   live_process_stream?: true,
                   service_host?: false,
                   snapshot_modes: [:microvm_snapshot],
                   provider_transport: :test
                 )
             )

    assert capabilities.exec?
    refute capabilities.checkpoints?
    assert capabilities.streaming?
    assert Capabilities.attach_mode(capabilities) == :live_stream
    assert Capabilities.attach_supported?(capabilities)
    assert Capabilities.streaming_live?(capabilities)
    assert Capabilities.stdin_supported?(capabilities)
    assert Capabilities.stdin_close_supported?(capabilities)
    assert Capabilities.stderr_separate?(capabilities)
    refute Capabilities.terminal_result_adapter?(capabilities)
    refute Capabilities.mcp_boundary_supported?(capabilities)
    refute Capabilities.restricted_egress_supported?(capabilities)
    refute Capabilities.pty_supported?(capabilities)
    assert Capabilities.state_tier(capabilities) == :persistent_process_host
    assert Capabilities.process_host?(capabilities)
    assert Capabilities.workspace_persistent?(capabilities)
    assert Capabilities.live_process_stream?(capabilities)
    refute Capabilities.service_host?(capabilities)
    assert Capabilities.snapshot_modes(capabilities) == [:microvm_snapshot]

    terminal_capabilities =
      Capabilities.one_shot_exec(
        streaming?: true,
        metadata: Capabilities.attach_metadata(:terminal_adapter)
      )

    assert Capabilities.attach_mode(terminal_capabilities) == :terminal_adapter
    assert Capabilities.attach_supported?(terminal_capabilities)
    assert Capabilities.terminal_result_adapter?(terminal_capabilities)
    refute Capabilities.streaming_live?(terminal_capabilities)
    refute Capabilities.stdin_supported?(terminal_capabilities)
    assert Capabilities.state_tier(terminal_capabilities) == :one_shot_exec
    refute Capabilities.process_host?(terminal_capabilities)
    refute Capabilities.workspace_persistent?(terminal_capabilities)
    refute Capabilities.live_process_stream?(terminal_capabilities)
    refute Capabilities.service_host?(terminal_capabilities)
    assert Capabilities.snapshot_modes(terminal_capabilities) == []

    assert Capabilities.attach_mode(%{streaming?: false, metadata: %{}}) == :none

    assert {:error, error} =
             Capabilities.new(exec?: true, metadata: %{attach_mode: :made_up})

    assert error.message == "invalid sandbox attach capability mode"

    assert {:error, error} =
             Capabilities.new(exec?: true, metadata: %{state_tier: :made_up})

    assert error.message == "invalid sandbox lifecycle state tier"

    assert {:error, error} =
             Capabilities.new(exec?: true, metadata: %{snapshot_modes: [:filesystem, :made_up]})

    assert error.message == "invalid sandbox snapshot capability mode"

    assert {:ok, session} =
             Session.new(
               id: "session-1",
               sandbox: :local_code,
               backend: :docker,
               state: "ready",
               capabilities: capabilities,
               isolation_level: :container,
               state_model: "persistent_workspace",
               transport_model: "docker_cli",
               persistent_identity?: true,
               workspace_ref: "workspace://session-1",
               policy: [network: :disabled, allowed_runtimes: [:bash]]
             )

    assert session.state == :ready
    assert session.state_model == :persistent_workspace
    assert session.transport_model == :docker_cli

    assert {:ok, file} = FileRef.new(path: "/workspace/out.txt", kind: "file", bytes: 3)
    assert file.kind == :file

    assert {:ok, checkpoint} =
             Checkpoint.new(
               id: "checkpoint-1",
               session_id: session.id,
               backend: session.backend,
               ref: "checkpoint://session-1/1"
             )

    assert checkpoint.backend == :docker

    assert Checkpoint.kinds() == [
             :filesystem,
             :microvm_snapshot,
             :memory_snapshot,
             :provider_checkpoint,
             :suspended_session
           ]

    assert Checkpoint.kind(checkpoint) == nil
    assert Checkpoint.preserves(:filesystem).filesystem
    refute Checkpoint.preserves(:filesystem).process_memory
    assert Checkpoint.preserves(:provider_checkpoint).running_service_state == :provider_dependent
    assert Checkpoint.support_matrix().microvm_snapshot.running_processes

    assert {:ok, service} = Service.new(id: "svc", session_id: session.id, name: "web")
    assert service.status == :starting

    assert {:ok, proxy} =
             Proxy.new(
               id: "proxy",
               session_id: session.id,
               backend: session.backend,
               service_id: service.id
             )

    assert proxy.status == :opening

    assert {:error, error} =
             Proxy.new(id: "proxy", session_id: session.id, service_id: service.id)

    assert error.message =~ "backend"

    assert {:ok, lease} =
             Lease.new(
               id: "lease",
               session_id: session.id,
               backend: session.backend,
               resource: "workspace"
             )

    assert lease.mode == :exclusive
    assert {:error, error} = Lease.new(id: "lease", session_id: session.id, resource: "workspace")
    assert error.message =~ "backend"

    assert {:ok, event} =
             SessionEvent.new(id: "event", session_id: session.id, type: "checkpoint_created")

    assert event.type == :checkpoint_created

    assert {:ok, stdout_event} =
             SessionEvent.new(id: "stdout", session_id: session.id, type: "stdout_chunk")

    assert stdout_event.type == :stdout_chunk

    assert {:ok, handle} =
             AttachHandle.new(
               id: "attach",
               session_id: session.id,
               backend: session.backend,
               events: [stdout_event]
             )

    assert handle.status == :open
    assert Enum.to_list(AttachHandle.events(handle)) == [stdout_event]

    assert {:ok, process} =
             ProcessHandle.new(
               id: "process",
               session_id: session.id,
               backend: session.backend,
               status: "running",
               command: ["sleep", "60"],
               events: [stdout_event]
             )

    assert process.status == :running
    assert Enum.to_list(ProcessHandle.events(process)) == [stdout_event]

    assert {:ok, process_status} =
             ProcessStatus.from_handle(process, status: "exited", exit_status: 0)

    assert process_status.status == :exited
    assert process_status.exit_status == 0

    assert {:error, error} = Capabilities.new(exec?: :yes)
    assert error.message =~ "exec?"
    assert {:error, error} = Session.new(id: "", sandbox: :local_code, backend: :docker)
    assert error.message =~ "id"
  end

  test "attach bridge summarizes ordered chunks and handle metadata" do
    events = [
      bridge_event(:exec_started, %{runtime: :bash}, "start"),
      bridge_event(:stdout_chunk, %{stream: :stdout, chunk: "out-1"}, "out-1"),
      bridge_event(:stderr_chunk, %{"stream" => "stderr", "chunk" => "err"}, "err"),
      bridge_event(:stdout_chunk, %{chunk: ["out-", "2"]}, "out-2"),
      bridge_event(:exec_finished, %{status: :pass, exit_status: 0}, "done")
    ]

    handle =
      AttachHandle.new!(
        id: "attach-bridge",
        session_id: "session-bridge",
        backend: :docker,
        events: events,
        metadata: %{attach_mode: :live_stream, streaming_live?: true}
      )

    summary = AttachBridge.summarize(handle)

    assert summary.attach_id == "attach-bridge"
    assert summary.session_id == "session-bridge"
    assert summary.backend == :docker
    assert summary.status == :pass
    assert summary.exit_status == 0
    assert summary.stdout == "out-1out-2"
    assert summary.stderr == "err"
    assert summary.combined == "out-1errout-2"
    assert summary.chunk_counts == %{stdout: 2, stderr: 1}
    assert summary.byte_counts == %{stdout: 10, stderr: 3, combined: 13}
    assert summary.event_count == 5
    assert summary.terminal_count == 1
    refute summary.missing_terminal?
    refute summary.synthetic_terminal?
    assert summary.metadata == %{attach_mode: :live_stream, streaming_live?: true}
    assert Enum.map(summary.chunks, & &1.stream) == [:stdout, :stderr, :stdout]
  end

  test "attach bridge fails closed when stream lacks exec_finished" do
    summary =
      AttachBridge.summarize(
        [
          bridge_event(:stdout_chunk, %{stream: :stdout, chunk: "partial"}, "partial")
        ],
        attach_id: "missing-terminal",
        session_id: "session-bridge",
        backend: :vmsan
      )

    assert summary.status == :fail
    assert summary.exit_status == nil
    assert summary.stdout == "partial"
    assert summary.missing_terminal?
    assert summary.synthetic_terminal?
    assert summary.terminal_count == 0
    assert summary.effective_terminal.payload.reason == :missing_exec_finished
  end

  test "attach bridge lets backend failure override earlier success terminal" do
    summary =
      AttachBridge.summarize([
        bridge_event(:exec_finished, %{status: :pass, exit_status: 0}, "success"),
        bridge_event(:exec_finished, %{status: :fail, exit_status: 42}, "failure")
      ])

    assert summary.status == :fail
    assert summary.exit_status == 42
    assert summary.terminal_count == 2
    assert summary.effective_terminal.event_id == "failure"
    assert summary.last_terminal.event_id == "failure"
  end

  test "attach bridge keeps first repeated success as effective terminal" do
    summary =
      AttachBridge.summarize([
        bridge_event(:exec_finished, %{status: :pass, exit_status: 0}, "success-1"),
        bridge_event(:exec_finished, %{status: :pass, exit_status: 0}, "success-2")
      ])

    assert summary.status == :pass
    assert summary.terminal_count == 2
    assert summary.effective_terminal.event_id == "success-1"
    assert summary.last_terminal.event_id == "success-2"
  end

  test "backend default session adapter preserves one-shot execution and unsupported capabilities" do
    assert {:ok, profile} =
             Profile.new(
               name: :local_code,
               backend: :just_bash,
               runtimes: [:bash],
               network: :disabled
             )

    assert {:ok, unsigned_session} =
             Backend.open_session(LitterBox.Backends.JustBash, profile, [])

    assert unsigned_session.backend == :just_bash
    assert unsigned_session.capabilities.exec?
    refute unsigned_session.capabilities.checkpoints?
    assert unsigned_session.state_model == :one_shot

    assert {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)
    assert session.backend == :just_bash
    assert session.capabilities.exec?
    refute session.capabilities.checkpoints?
    assert session.state_model == :one_shot

    assert {:ok, result} =
             LitterBox.exec(session, runtime: :bash, source: "echo session-contract")

    assert result.status == :pass
    assert result.stdout == "session-contract\n"

    assert {:error, error} = LitterBox.write_file(session, "/workspace/a.txt", "a")
    assert error.message == "sandbox backend does not support write_file"
    assert error.details.backend == :just_bash
    assert :ok = LitterBox.close_session(session)
  end

  test "fake backend exercises session capability callbacks" do
    assert {:ok, profile} =
             Profile.new(
               name: :local_code,
               backend: :docker,
               runtimes: [:bash],
               network: :disabled
             )

    assert {:ok, session} = Backend.open_session(FakeBackend, profile, [])
    assert session.state_model == :checkpointable
    assert session.transport_model == :local_microvm
    assert session.capabilities.files?
    assert session.capabilities.services?
    assert session.capabilities.streaming?

    assert {:ok, file} = Backend.write_file(FakeBackend, session, "/workspace/a.txt", "abc", [])
    assert file.bytes == 3

    assert {:ok, "fake:/workspace/a.txt"} =
             Backend.read_file(FakeBackend, session, "/workspace/a.txt", [])

    assert {:ok, [%FileRef{}]} = Backend.list_files(FakeBackend, session, "/workspace", [])
    assert :ok = Backend.delete_file(FakeBackend, session, "/workspace/a.txt", [])

    assert {:ok, result} =
             Backend.exec_session(
               FakeBackend,
               session,
               ExecutionRequest.new!(sandbox: :local_code, runtime: :bash, source: "ok"),
               []
             )

    assert result.stdout == "ok"

    assert {:ok, handle} =
             Backend.attach_session(
               FakeBackend,
               session,
               ExecutionRequest.new!(sandbox: :local_code, runtime: :bash, source: "stream-ok"),
               []
             )

    assert %AttachHandle{id: "attach-1", backend: :docker} = handle

    assert [:exec_started, :stdout_chunk, :exec_finished] =
             handle.events |> Enum.map(& &1.type)

    assert :ok = Backend.write_stdin(FakeBackend, handle, "hello\n", [])
    assert :ok = Backend.close_attach(FakeBackend, handle, [])

    assert {:ok, process} =
             Backend.start_process(
               FakeBackend,
               session,
               ExecutionRequest.new!(sandbox: :local_code, runtime: :bash, source: "process-ok"),
               []
             )

    assert %ProcessHandle{id: "process-1", backend: :docker, status: :running} = process
    assert [:process_started, :stdout_chunk] = process.events |> Enum.map(& &1.type)

    assert {:ok, [status]} = Backend.list_processes(FakeBackend, session, [])
    assert %ProcessStatus{id: "process-1", status: :running} = status

    assert {:ok, status} = Backend.process_status(FakeBackend, session, process, [])
    assert status.id == process.id
    assert status.status == :running

    assert {:ok, events} = Backend.process_events(FakeBackend, process, [])
    assert [:process_started, :stdout_chunk] = events |> Enum.map(& &1.type)

    assert :ok = Backend.write_process_stdin(FakeBackend, process, "input\n", [])
    assert :ok = Backend.close_process_stdin(FakeBackend, process, [])
    assert :ok = Backend.signal_process(FakeBackend, process, :term, [])
    assert :ok = Backend.kill_process(FakeBackend, process, [])
    assert {:ok, waited} = Backend.wait_process(FakeBackend, process, [])
    assert waited.status == :exited
    assert waited.exit_status == 0

    assert {:ok, checkpoint} = Backend.checkpoint(FakeBackend, session, [], [])
    assert checkpoint.session_id == session.id
    assert {:ok, ^session} = Backend.restore(FakeBackend, session, checkpoint, [])
    assert {:ok, service} = Backend.start_service(FakeBackend, session, [name: "web"], [])
    assert service.status == :running
    assert {:ok, [%Service{status: :running}]} = Backend.list_services(FakeBackend, session, [])
    assert {:ok, proxy} = Backend.open_proxy(FakeBackend, session, service, [])
    assert proxy.status == :open
    assert :ok = Backend.close_proxy(FakeBackend, proxy, [])
    assert {:ok, lease} = Backend.acquire_lease(FakeBackend, session, "workspace", [])
    assert lease.status == :active
    assert :ok = Backend.release_lease(FakeBackend, lease, [])
    assert {:error, error} = LitterBox.close_proxy("proxy-1")
    assert error.message =~ "requires a backend"
    assert :ok = Backend.close_session(FakeBackend, session, [])
  end

  test "backend attach dispatcher fails closed when callback is unsupported" do
    assert {:ok, session} =
             LitterBox.open_session(:local_code, [],
               profile: [
                 name: :local_code,
                 backend: :just_bash,
                 runtimes: [:bash],
                 network: :disabled
               ]
             )

    request = ExecutionRequest.new!(sandbox: :local_code, runtime: :bash, source: "echo fallback")

    assert {:error, error} = Backend.attach_session(NoAttachBackend, session, request, [])

    assert error.message == "sandbox backend does not support attach_session"
    assert error.details.operation == :attach_session

    assert {:error, error} = Backend.start_process(NoAttachBackend, session, request, [])
    assert error.message == "sandbox backend does not support start_process"
    assert error.details.operation == :start_process

    assert {:error, error} =
             LitterBox.start_process(session, runtime: :bash, source: "sleep 1")

    assert error.message == "sandbox session does not support process hosting"

    assert :ok = LitterBox.close_session(session)
  end

  test "restricted egress allow-lists fail closed when backend cannot enforce them" do
    assert {:ok, profile} =
             Profile.new(
               name: :local_code,
               backend: :vmsan,
               runtimes: [:bash],
               policy: [
                 network: :restricted,
                 metadata: %{
                   egress_allowlist: [
                     %{scheme: "http", host: "host.docker.internal", port: 4567, purpose: :mcp}
                   ]
                 }
               ]
             )

    assert profile.policy.network == :restricted
    assert LitterBox.Policy.restricted_egress_requested?(profile.policy)

    assert {:error, error} =
             LitterBox.exec(
               %{
                 sandbox: :local_code,
                 runtime: :bash,
                 source: "echo should-not-run",
                 network: :restricted
               },
               profile: profile
             )

    assert error.message == "sandbox restricted egress allow-list is not supported by backend"
    assert error.details.backend == :vmsan
    refute error.details.restricted_egress_supported?
    assert error.details.policy.restricted_egress?

    assert {:error, error} = LitterBox.open_session(:local_code, [], profile: profile)
    assert error.message == "sandbox restricted egress allow-list is not supported by backend"
  end

  test "docker accepts egress allow-list and MCP/model egress-boundary policy shape" do
    assert {:ok, profile} =
             Profile.new(
               name: :local_code,
               backend: :docker,
               runtimes: [:bash],
               network: :restricted,
               egress_allowlist: [
                 %{scheme: "http", host: "host.docker.internal", port: 4000, purpose: :mcp},
                 %{scheme: "http", host: "host.docker.internal", port: 4100, purpose: :model}
               ],
               mcp_boundary: %{transport: :egress_allowlist, purpose: :mcp}
             )

    assert profile.policy.network == :restricted
    assert LitterBox.Policy.restricted_egress_requested?(profile.policy)
    assert LitterBox.Policy.mcp_boundary_requested?(profile.policy)

    assert LitterBox.Policy.egress_allowlist(profile.policy) == [
             %{scheme: "http", host: "host.docker.internal", port: 4000, purpose: "mcp"},
             %{scheme: "http", host: "host.docker.internal", port: 4100, purpose: "model"}
           ]

    request =
      ExecutionRequest.new!(
        sandbox: :local_code,
        runtime: :bash,
        source: "echo allowed",
        network: :restricted
      )

    assert :ok = LitterBox.authorize_request(profile, request)
  end

  test "docker rejects restricted egress shapes outside the local MCP unblock" do
    if docker_image_available?() do
      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:bash],
                 network: :restricted,
                 egress_allowlist: [
                   %{scheme: "https", host: "example.com", port: 443, purpose: :model}
                 ],
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      assert {:error, error} =
               LitterBox.exec(
                 [
                   sandbox: :local_code,
                   runtime: :bash,
                   source: "echo blocked",
                   network: :restricted
                 ],
                 profile: profile
               )

      assert error.message == "docker restricted egress allow-list entry is not supported"
      assert error.details.reason == "host must be host.docker.internal"
    end
  end

  test "MCP boundary requests fail closed when backend cannot provide the boundary" do
    assert {:ok, profile} =
             Profile.new(
               name: :local_code,
               backend: :docker,
               runtimes: [:bash],
               policy: [
                 network: :restricted,
                 metadata: %{
                   mcp_boundary: %{transport: :host_forward, host: "127.0.0.1", port: 4567}
                 }
               ]
             )

    assert profile.policy.network == :restricted
    assert LitterBox.Policy.mcp_boundary_requested?(profile.policy)
    refute LitterBox.Policy.restricted_egress_requested?(profile.policy)

    assert {:error, error} =
             LitterBox.exec(
               %{
                 sandbox: :local_code,
                 runtime: :bash,
                 source: "echo should-not-run",
                 network: :restricted
               },
               profile: profile
             )

    assert error.message == "sandbox MCP boundary is not supported by backend"
    assert error.details.backend == :docker
    refute error.details.mcp_boundary_supported?
    assert error.details.policy.mcp_boundary.transport == "host_forward"

    assert {:error, error} = LitterBox.open_session(:local_code, [], profile: profile)
    assert error.message == "sandbox MCP boundary is not supported by backend"
  end

  test "session authority rejects mutated handles before backend execution" do
    assert {:ok, profile} =
             Profile.new(
               name: :local_code,
               backend: :just_bash,
               runtimes: [:bash],
               network: :disabled
             )

    assert {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)

    forged =
      put_in(session.policy.network, :host)

    assert {:error, error} =
             LitterBox.exec(forged,
               runtime: :bash,
               source: "echo should-not-run",
               network: :host
             )

    assert error.message == "sandbox session authority snapshot does not match the handle"

    forged =
      put_in(session.capabilities.exec?, false)

    assert {:error, error} = LitterBox.exec(forged, runtime: :bash, source: "echo no")
    assert error.message == "sandbox session authority snapshot does not match the handle"
    refute function_exported?(LitterBox.Session, :reseal, 1)
    refute Code.ensure_loaded?(LitterBox.SessionAuthority)
  end

  test "session authority secret initialization is safe under concurrent opens" do
    :persistent_term.erase({LitterBox, :session_authority_secret})

    assert {:ok, profile} =
             Profile.new(
               name: :local_code,
               backend: :just_bash,
               runtimes: [:bash],
               network: :disabled
             )

    parent = self()

    tasks =
      for index <- 1..32 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          with {:ok, session} <- LitterBox.open_session(:local_code, [], profile: profile),
               {:ok, result} <-
                 LitterBox.exec(session,
                   runtime: :bash,
                   source: "echo authority-#{index}"
                 ),
               :ok <- LitterBox.close_session(session) do
            {:ok, result.stdout}
          end
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}, 1_000
        pid
      end

    Enum.each(pids, &send(&1, :go))

    assert tasks
           |> Task.await_many(5_000)
           |> Enum.all?(fn
             {:ok, stdout} -> String.starts_with?(stdout, "authority-")
             _other -> false
           end)
  end

  test "session operations enforce profile isolation and close revocation" do
    assert {:error, error} =
             LitterBox.open_session(:local_code, [],
               profile: [
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:bash],
                 network: :disabled,
                 policy: [isolation_minimum: :microvm]
               ]
             )

    assert error.message == "sandbox isolation level is below profile policy"

    assert {:ok, profile} =
             Profile.new(
               name: :local_code,
               backend: :just_bash,
               runtimes: [:bash],
               network: :disabled
             )

    assert {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)
    assert :ok = LitterBox.close_session(session)

    assert {:error, error} = LitterBox.exec(session, runtime: :bash, source: "echo no")
    assert error.message == "sandbox session authority is not active"

    assert {:error, error} = LitterBox.checkpoint(session)
    assert error.message == "sandbox session authority is not active"
  end

  test "backend health reports expose capability metadata" do
    profiles = [
      Profile.new!(name: :just_bash, backend: :just_bash, runtimes: [:bash]),
      Profile.new!(name: :lua, backend: :lua, runtimes: [:lua]),
      Profile.new!(name: :docker, backend: :docker, runtimes: [:bash]),
      Profile.new!(name: :gvisor, backend: :gvisor, runtimes: [:bash]),
      Profile.new!(name: :vmsan, backend: :vmsan, runtimes: [:bash]),
      Profile.new!(
        name: :remote_fly,
        backend: :remote,
        runtimes: [:bash],
        network: :restricted,
        backend_options: [
          provider: :fly_machines,
          app: "runic-sandbox-test",
          machine_id: "machine-test-id",
          executable: "runic-sandbox-missing-flyctl"
        ]
      )
    ]

    for profile <- profiles do
      assert {:ok, status} = LitterBox.status(profile: profile)
      health = hd(status.backends)
      assert is_map(health.capabilities)
      assert is_boolean(health.capabilities.exec?)
      assert is_boolean(health.capabilities.checkpoints?)
      assert is_boolean(health.capabilities.inline_files?)
      assert is_boolean(health.capabilities.session_files?)
      assert is_boolean(health.capabilities.services?)
      assert is_boolean(health.capabilities.proxy?)
      assert is_boolean(health.capabilities.streaming?)
      assert health.capabilities.streaming?
      assert is_boolean(health.capabilities.persistent_identity?)

      expected_attach_mode =
        if profile.backend in [:docker, :gvisor], do: :live_stream, else: :terminal_adapter

      assert Capabilities.attach_mode(health.capabilities) == expected_attach_mode
      assert Capabilities.attach_supported?(health.capabilities)

      assert Capabilities.stdin_supported?(health.capabilities) ==
               (expected_attach_mode == :live_stream)

      assert Capabilities.streaming_live?(health.capabilities) ==
               (expected_attach_mode == :live_stream)

      assert Capabilities.terminal_result_adapter?(health.capabilities) ==
               (expected_attach_mode == :terminal_adapter)

      expected_lifecycle =
        case profile.backend do
          backend when backend in [:just_bash, :lua] ->
            %{
              state_tier: :one_shot_exec,
              process_host?: false,
              workspace_persistent?: false,
              live_process_stream?: false,
              service_host?: false,
              snapshot_modes: []
            }

          backend when backend in [:docker, :gvisor] ->
            %{
              state_tier: :one_shot_exec,
              process_host?: false,
              workspace_persistent?: false,
              live_process_stream?: true,
              service_host?: false,
              snapshot_modes: []
            }

          :vmsan ->
            %{
              state_tier: :persistent_process_host,
              process_host?: true,
              workspace_persistent?: true,
              live_process_stream?: true,
              service_host?: false,
              snapshot_modes: [:microvm_snapshot]
            }

          :remote ->
            %{
              state_tier: :persistent_workspace,
              process_host?: false,
              workspace_persistent?: true,
              live_process_stream?: false,
              service_host?: false,
              snapshot_modes: []
            }
        end

      assert Capabilities.state_tier(health.capabilities) == expected_lifecycle.state_tier
      assert Capabilities.process_host?(health.capabilities) == expected_lifecycle.process_host?

      assert Capabilities.workspace_persistent?(health.capabilities) ==
               expected_lifecycle.workspace_persistent?

      assert Capabilities.live_process_stream?(health.capabilities) ==
               expected_lifecycle.live_process_stream?

      assert Capabilities.service_host?(health.capabilities) == expected_lifecycle.service_host?
      assert Capabilities.snapshot_modes(health.capabilities) == expected_lifecycle.snapshot_modes
    end
  end

  test "in-process backends expose terminal attach streams through the facade" do
    assert {:ok, bash_session} =
             LitterBox.open_session(:local_code, [],
               profile: [
                 name: :local_code,
                 backend: :just_bash,
                 runtimes: [:bash],
                 network: :disabled
               ]
             )

    assert bash_session.capabilities.streaming?

    assert {:ok, bash_handle} =
             LitterBox.attach(bash_session, runtime: :bash, source: "echo attach-bash")

    assert bash_handle.status == :closed
    assert bash_handle.metadata.streaming_live? == false
    assert attach_event_types(bash_handle) == [:exec_started, :stdout_chunk, :exec_finished]
    assert attach_stdout(bash_handle) == "attach-bash\n"

    assert {:error, error} = LitterBox.write_stdin(bash_handle, "ignored\n")
    assert error.message == "terminal attach result does not accept stdin after execution"
    assert :ok = LitterBox.close_attach(bash_handle)
    assert :ok = LitterBox.close_session(bash_session)

    if Code.ensure_loaded?(Lua) do
      assert {:ok, lua_session} =
               LitterBox.open_session(:lua_code, [],
                 profile: [
                   name: :lua_code,
                   backend: :lua,
                   runtimes: [:lua],
                   network: :disabled
                 ]
               )

      assert lua_session.capabilities.streaming?

      assert {:ok, lua_handle} =
               LitterBox.attach(lua_session, runtime: :lua, source: "return 'attach-lua'")

      assert lua_handle.metadata.streaming_live? == false
      assert attach_event_types(lua_handle) == [:exec_started, :stdout_chunk, :exec_finished]
      assert attach_stdout(lua_handle) == ~s("attach-lua"\n)
      assert :ok = LitterBox.close_session(lua_session)
    end
  end

  test "remote backend health is structured without contacting the provider" do
    assert {:ok, profile} =
             Profile.new(
               name: :remote_code,
               backend: :remote,
               runtimes: [:bash],
               network: :restricted,
               backend_options: [
                 provider: :fly_machines,
                 app: "runic-sandbox-test",
                 machine_id: "machine-test-id",
                 token_env: "RUNIC_SANDBOX_MISSING_FLY_TOKEN",
                 executable: "runic-sandbox-missing-flyctl"
               ]
             )

    assert {:ok, status} = LitterBox.status(profile: profile)

    assert [
             %{
               name: :remote,
               isolation_level: :remote_microvm,
               security_boundary?: true,
               configured?: true,
               fly_cli_available?: false,
               available?: false,
               auth_configured?: false,
               auth_required?: true,
               credential_policy: :env_token
             } = health
           ] = status.backends

    refute Map.has_key?(health, :provider_config)
    assert %{message: "fly or flyctl executable is unavailable"} in health.diagnostics

    assert %{requirement: :auth, message: "Remote provider credentials are required"} in health.missing_requirements

    assert health.capabilities.metadata.provider_api_capabilities == %{
             exec?: true,
             ps?: true,
             signal?: true,
             suspend?: true,
             live_process_contract?: false,
             reason: :fly_machines_api_client_not_implemented
           }
  end

  test "remote backend does not expose provider config through status or snapshot" do
    assert {:ok, profile} =
             Profile.new(
               name: :remote_code,
               backend: :remote,
               runtimes: [:bash],
               network: :restricted,
               backend_options: [
                 provider: :fly_machines,
                 app: "runic-sandbox-test",
                 machine_id: "machine-test-id",
                 token_env: "RUNIC_SANDBOX_MISSING_FLY_TOKEN",
                 executable: "runic-sandbox-missing-flyctl"
               ]
             )

    assert {:ok, status} = LitterBox.status(profile: profile)
    health = hd(status.backends)
    refute Map.has_key?(health, :provider_config)
    refute inspect(health) =~ "machine-test-id"

    assert {:ok, instance} = LitterBox.provision(profile)
    assert {:ok, snapshot} = LitterBox.snapshot(instance)
    refute Map.has_key?(snapshot, :provider_config)
    refute inspect(snapshot) =~ "machine-test-id"
  end

  test "remote credential policy none is not executable through ambient CLI auth" do
    assert {:ok, profile} =
             Profile.new(
               name: :remote_code,
               backend: :remote,
               runtimes: [:bash],
               network: :restricted,
               backend_options: [
                 provider: :fly_machines,
                 app: "runic-sandbox-test",
                 machine_id: "machine-test-id",
                 credential_policy: :none,
                 executable: "sh"
               ]
             )

    assert {:ok, status} = LitterBox.status(profile: profile)
    health = hd(status.backends)
    refute health.available?
    assert health.credential_policy == :none

    assert %{requirement: :auth, message: "Remote provider credentials are required"} in health.missing_requirements

    assert {:ok, instance} = LitterBox.provision(profile)

    assert {:error, error} =
             LitterBox.exec_with_instance(
               instance,
               ExecutionRequest.new!(sandbox: :remote_code, runtime: :bash, source: "echo no")
             )

    assert error.message == "remote sandbox provider is not available for execution"
  end

  test "remote backend adapts provider exec output into terminal attach events" do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "litter_box_remote_#{System.unique_integer([:positive])}.sh"
      )

    output = Jason.encode!(%{stdout: "remote-attach\n", stderr: "", exit_status: 0})

    File.write!(script_path, """
    #!/bin/sh
    case "$*" in
      *"machine exec --app runic-sandbox-test --json --timeout 30 machine-test-id sh -lc"*)
        printf '%s\\n' '#{output}'
        ;;
      *)
        printf '%s\\n' '{"stdout":"","stderr":"bad argv","exit_status":64}'
        ;;
    esac
    """)

    File.chmod!(script_path, 0o755)

    try do
      assert {:ok, profile} =
               Profile.new(
                 name: :remote_code,
                 backend: :remote,
                 runtimes: [:bash],
                 network: :restricted,
                 backend_options: [
                   provider: :fly_machines,
                   app: "runic-sandbox-test",
                   machine_id: "machine-test-id",
                   credential_policy: :ambient_cli_allowed,
                   executable: script_path
                 ]
               )

      assert {:ok, session} = LitterBox.open_session(:remote_code, [], profile: profile)
      assert session.capabilities.streaming?

      assert {:ok, handle} =
               LitterBox.attach(session, runtime: :bash, source: "echo remote-attach")

      assert handle.metadata.streaming_live? == false
      assert handle.metadata.provider_transport == :fly_machine_exec
      assert attach_event_types(handle) == [:exec_started, :stdout_chunk, :exec_finished]
      assert attach_stdout(handle) == "remote-attach\n"
      assert :ok = LitterBox.close_session(session)
    after
      File.rm(script_path)
    end
  end

  test "docker one-shot workspace is cleaned when file preparation fails" do
    FakeDocker.with_fake_docker(fn _docker_log ->
      before = tmp_litter_box_dirs()

      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:bash],
                 network: :disabled,
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      assert {:error, error} =
               LitterBox.exec(
                 [
                   sandbox: :local_code,
                   runtime: :bash,
                   source: "echo blocked",
                   files: %{"ok.txt" => "secret", "../escape.txt" => "blocked"}
                 ],
                 profile: profile
               )

      assert error.message == "failed to prepare docker sandbox workspace"
      assert tmp_litter_box_dirs() -- before == []
    end)
  end

  test "docker session persists files, checkpoints, and restores when local image exists" do
    if docker_image_available?() do
      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:bash],
                 network: :disabled,
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      assert {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)
      assert session.state_model == :persistent_workspace
      assert session.capabilities.session_files?
      assert session.capabilities.checkpoints?
      assert Capabilities.state_tier(session.capabilities) == :persistent_process_host
      assert Capabilities.workspace_persistent?(session.capabilities)
      assert Capabilities.process_host?(session.capabilities)
      assert Capabilities.live_process_stream?(session.capabilities)
      assert Capabilities.snapshot_modes(session.capabilities) == [:filesystem]
      assert is_binary(session.metadata.container_name)

      assert {:ok, ref} = LitterBox.write_file(session, "input.txt", "alpha")
      assert ref.path == "input.txt"
      assert {:ok, "alpha"} = LitterBox.read_file(session, "input.txt")

      assert {:ok, result} =
               LitterBox.exec(session,
                 runtime: :bash,
                 source: "cat input.txt > output.txt && printf done"
               )

      assert result.status == :pass
      assert result.stdout == "done"
      assert result.metadata.container_name == session.metadata.container_name
      assert {:ok, "alpha"} = LitterBox.read_file(session, "output.txt")

      assert {:ok, process} =
               LitterBox.start_process(session,
                 runtime: :bash,
                 source: "read line; printf \"$line\" > process.txt"
               )

      assert process.status == :running
      assert :ok = LitterBox.write_process_stdin(process, "from-process\n")
      assert {:ok, process_events} = LitterBox.process_events(process)
      assert [:process_started, :process_finished] = Enum.map(process_events, & &1.type)
      assert {:ok, "from-process"} = LitterBox.read_file(session, "process.txt")

      assert {:ok, files} = LitterBox.list_files(session)
      assert Enum.any?(files, &(&1.path == "input.txt"))
      assert Enum.any?(files, &(&1.path == "output.txt"))
      assert Enum.any?(files, &(&1.path == "process.txt"))

      assert {:ok, checkpoint} = LitterBox.checkpoint(session, id: "phase2")
      assert checkpoint.metadata.kind == :filesystem
      assert checkpoint.metadata.preserves.filesystem
      refute checkpoint.metadata.preserves.process_memory
      refute checkpoint.metadata.preserves.running_service_state
      assert hd(checkpoint.metadata.caveats) =~ "files only"
      assert checkpoint.metadata.authority.version == 1
      assert {:ok, _ref} = LitterBox.write_file(session, "input.txt", "beta")
      assert {:ok, "beta"} = LitterBox.read_file(session, "input.txt")
      assert {:ok, restored} = LitterBox.restore(session, checkpoint)
      assert {:ok, "alpha"} = LitterBox.read_file(restored, "input.txt")
      assert :ok = LitterBox.delete_file(restored, "output.txt")
      assert {:ok, files} = LitterBox.list_files(restored)
      refute Enum.any?(files, &(&1.path == "output.txt"))
      assert :ok = LitterBox.close_session(restored)
      assert {:error, error} = LitterBox.exec(restored, runtime: :bash, source: "echo no")
      assert error.message == "sandbox session authority is not active"
    end
  end

  test "managed docker warm pool reuses and cleans persistent containers" do
    if docker_image_available?() do
      name = :"litter_box_docker_warm_#{System.unique_integer([:positive])}"

      start_supervised!(
        {LitterBox,
         name: name,
         sandboxes: [
           local_code: [
             backend: :docker,
             runtimes: [:bash],
             network: :disabled,
             image: "runic-ai/sandbox:elixir-python-node",
             pool: [warm: 1, max: 1, idle_ttl_ms: :infinity]
           ]
         ]}
      )

      assert {:ok, first} = LitterBox.acquire_session(:local_code, [], server: name)
      container_name = first.metadata.container_name
      assert docker_container_exists?(container_name)

      assert {:ok, process} =
               LitterBox.start_process(
                 first,
                 [runtime: :bash, source: "printf ready; sleep 30"],
                 server: name
               )

      assert {:ok, events} = LitterBox.process_events(process)
      assert [:process_started, :stdout_chunk] = events |> Enum.take(2) |> Enum.map(& &1.type)

      assert {:error, error} = LitterBox.release_session(first, server: name)
      assert error.message == "sandbox session has active processes"
      assert :ok = LitterBox.kill_process(process, server: name)

      assert :ok = LitterBox.release_session(first, server: name)
      assert {:ok, second} = LitterBox.acquire_session(:local_code, [], server: name)
      assert second.id == first.id
      assert second.metadata.container_name == container_name

      assert :ok = LitterBox.close_session(second, server: name)
      refute docker_container_exists?(container_name)
    end
  end

  test "docker restricted session close removes egress resources" do
    if docker_image_available?() do
      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:bash],
                 network: :restricted,
                 egress_allowlist: [
                   %{scheme: "http", host: "host.docker.internal", port: 4000, purpose: :mcp}
                 ],
                 mcp_boundary: %{transport: :egress_allowlist, purpose: :mcp},
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      assert {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)
      container_name = session.metadata.container_name
      network_name = session.metadata.network.network
      proxy_name = session.metadata.network.proxy_container

      assert docker_container_exists?(container_name)
      assert docker_container_exists?(proxy_name)
      assert docker_network_exists?(network_name)

      assert :ok = LitterBox.close_session(session)
      refute docker_container_exists?(container_name)
      refute docker_container_exists?(proxy_name)
      refute docker_network_exists?(network_name)
    end
  end

  test "managed docker owner death and manager termination clean containers" do
    if docker_image_available?() do
      name = :"litter_box_docker_owner_#{System.unique_integer([:positive])}"
      parent = self()

      start_supervised!(
        {LitterBox,
         name: name,
         sandboxes: [
           local_code: [
             backend: :docker,
             runtimes: [:bash],
             network: :disabled,
             image: "runic-ai/sandbox:elixir-python-node",
             pool: [warm: 0, max: 1]
           ]
         ]}
      )

      owner =
        spawn(fn ->
          {:ok, session} = LitterBox.acquire_session(:local_code, [], server: name)
          send(parent, {:docker_owner_session, session.metadata.container_name})
        end)

      assert_receive {:docker_owner_session, owner_container}, 5_000
      ref = Process.monitor(owner)
      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}
      assert wait_until(fn -> not docker_container_exists?(owner_container) end, 2_000)

      assert {:ok, session} = LitterBox.acquire_session(:local_code, [], server: name)
      manager_container = session.metadata.container_name
      assert docker_container_exists?(manager_container)

      assert :ok = LitterBox.release_session(session, server: name)
      assert :ok = stop_supervised(name)
      assert wait_until(fn -> not docker_container_exists?(manager_container) end, 2_000)
    end
  end

  test "docker services expose explicit localhost proxies and clean up" do
    if docker_image_available?() do
      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:bash],
                 network: :disabled,
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      assert {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)
      assert {:ok, _ref} = LitterBox.write_file(session, "index.html", "hello-service")

      assert {:ok, service} =
               LitterBox.start_service(session,
                 name: "web",
                 cmd: "python3",
                 args: ["-m", "http.server", "8765", "--bind", "127.0.0.1"],
                 port: 8765,
                 readiness: [type: :http, port: 8765, path: "/"]
               )

      assert service.status == :running
      assert [%{port: 8765}] = service.ports

      assert {:ok, [listed]} = LitterBox.list_services(session)
      assert listed.id == service.id
      assert listed.status == :running

      assert {:ok, proxy} = LitterBox.open_proxy(session, service)
      assert proxy.url =~ "http://127.0.0.1:"
      assert {:ok, 200, body} = host_http_get(proxy.url)
      assert body =~ "hello-service"

      assert :ok = LitterBox.stop_service(session, service)
      assert wait_until(fn -> match?({:error, _reason}, host_http_get(proxy.url)) end, 2_000)
      assert :ok = LitterBox.close_proxy(proxy)

      assert {:ok, replacement} =
               LitterBox.start_service(session,
                 name: "web2",
                 cmd: "python3",
                 args: ["-m", "http.server", "8766", "--bind", "127.0.0.1"],
                 port: 8766,
                 readiness: [type: :http, port: 8766, path: "/"]
               )

      assert {:ok, close_proxy} = LitterBox.open_proxy(session, replacement)
      assert {:ok, 200, _body} = host_http_get(close_proxy.url)
      assert :ok = LitterBox.close_session(session)

      assert wait_until(
               fn -> match?({:error, _reason}, host_http_get(close_proxy.url)) end,
               2_000
             )
    end
  end

  test "docker session rejects mutated metadata, symlink paths, and forged checkpoints" do
    if docker_image_available?() do
      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:bash],
                 network: :disabled,
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      assert {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)

      forged_session = put_in(session.metadata[:workspace_root], System.tmp_dir!())
      assert {:error, error} = LitterBox.read_file(forged_session, "passwd")
      assert error.message == "sandbox session authority snapshot does not match the handle"

      symlink_path = Path.join(session.metadata.workspace_root, "host-leak")
      assert :ok = File.ln_s("/etc/passwd", symlink_path)

      assert {:error, error} = LitterBox.read_file(session, "host-leak")
      assert error.message == "sandbox filesystem path may not be a symlink"

      assert {:ok, files} = LitterBox.list_files(session)
      refute Enum.any?(files, &(&1.path == "host-leak"))

      assert {:ok, result} =
               LitterBox.exec(session,
                 runtime: :bash,
                 source: "ln -s /etc/passwd container-leak"
               )

      assert result.status == :pass
      refute Enum.any?(result.files_changed, &(&1.path == "container-leak"))
      refute Enum.any?(result.artifacts, &(&1.path == "container-leak"))

      assert {:ok, checkpoint} = LitterBox.checkpoint(session, id: "authority")

      forged_path =
        Path.join(System.tmp_dir!(), "forged_checkpoint_#{System.unique_integer([:positive])}")

      File.mkdir_p!(forged_path)
      forged_checkpoint = put_in(checkpoint.metadata[:path], forged_path)
      assert {:error, error} = LitterBox.restore(session, forged_checkpoint)
      assert error.message == "docker checkpoint authority does not match"

      assert :ok = LitterBox.close_session(session)
    end
  end

  test "docker checkpoint ids cannot shape host checkpoint paths" do
    if docker_image_available?() do
      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:bash],
                 network: :disabled,
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      assert {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)

      target =
        Path.join(
          System.tmp_dir!(),
          "litter_box_path_escape_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(target)
      sentinel = Path.join(target, "sentinel.txt")
      File.write!(sentinel, "keep")

      escape_id = "a/../../../#{Path.basename(target)}"
      assert {:ok, checkpoint} = LitterBox.checkpoint(session, id: escape_id)

      assert File.read!(sentinel) == "keep"
      refute String.contains?(checkpoint.id, "/")

      assert String.starts_with?(
               Path.expand(checkpoint.metadata.path),
               Path.expand(System.tmp_dir!()) <> "/"
             )

      refute Path.expand(checkpoint.metadata.path) == Path.expand(target)

      assert :ok = LitterBox.close_session(session)
    end
  end

  test "docker session ids cannot shape host checkpoint paths" do
    if docker_image_available?() do
      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:bash],
                 network: :disabled,
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      target =
        Path.join(
          System.tmp_dir!(),
          "litter_box_session_id_escape_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(target)
      sentinel = Path.join(target, "sentinel.txt")
      File.write!(sentinel, "keep")

      session_id = "a/../#{Path.basename(target)}"

      assert {:ok, session} =
               LitterBox.open_session(:local_code, [], profile: profile, id: session_id)

      assert {:ok, checkpoint} = LitterBox.checkpoint(session, id: "phase2")

      assert File.read!(sentinel) == "keep"
      refute String.contains?(Path.basename(checkpoint.metadata.path), "/")

      assert String.starts_with?(
               Path.expand(checkpoint.metadata.path),
               Path.expand(System.tmp_dir!()) <> "/"
             )

      refute Path.expand(checkpoint.metadata.path) == Path.expand(target)

      assert :ok = LitterBox.close_session(session)
    end
  end

  test "docker session executes configured language runtimes when local image exists" do
    if docker_image_available?() do
      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:bash, :python, :node, :elixir, :lua],
                 network: :disabled,
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      assert {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)

      cases = [
        {:bash, "printf bash", "bash"},
        {:python, "print('python', end='')", "python"},
        {:node, "process.stdout.write('node')", "node"},
        {:elixir, "IO.write(\"elixir\")", "elixir"},
        {:lua, "io.write('lua')", "lua"}
      ]

      for {runtime, source, expected} <- cases do
        assert {:ok, result} = LitterBox.exec(session, runtime: runtime, source: source)
        assert result.status == :pass
        assert result.stdout == expected
      end

      assert :ok = LitterBox.close_session(session)
    end
  end

  test "docker session exposes live attach stream when local image exists" do
    if docker_image_available?() do
      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:bash],
                 network: :disabled,
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      assert {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)
      assert session.capabilities.streaming?

      assert {:ok, handle} =
               LitterBox.attach(session,
                 runtime: :bash,
                 source: "read line; printf \"$line\"; printf changed > attach.txt"
               )

      assert handle.metadata.streaming_live?
      assert :ok = LitterBox.write_stdin(handle, "live-docker\n")

      events = Enum.to_list(handle.events)
      assert [:exec_started, :stdout_chunk, :exec_finished] = Enum.map(events, & &1.type)
      assert events |> stdout_from_events() == "live-docker"

      finished = List.last(events)
      assert finished.payload.status == :pass
      assert Enum.any?(finished.payload.files_changed, &(&1.path == "attach.txt"))
      assert {:ok, "changed"} = LitterBox.read_file(session, "attach.txt")

      assert :ok = LitterBox.close_attach(handle)
      assert :ok = LitterBox.close_session(session)
    end
  end

  test "docker restricted egress reaches only allow-listed host MCP and model ports" do
    if docker_image_available?() do
      {:ok, server} = start_mcp_http_server("mcp-ok")
      {:ok, port} = :inet.port(server)
      {:ok, model_server} = start_mcp_http_server("model-ok")
      {:ok, model_port} = :inet.port(model_server)
      {:ok, denied_server} = start_mcp_http_server("should-not-be-reachable")
      {:ok, denied_port} = :inet.port(denied_server)

      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:python],
                 network: :restricted,
                 egress_allowlist: [
                   %{scheme: "http", host: "host.docker.internal", port: port, purpose: :mcp},
                   %{
                     scheme: "http",
                     host: "host.docker.internal",
                     port: model_port,
                     purpose: :model
                   }
                 ],
                 mcp_boundary: %{transport: :egress_allowlist, purpose: :mcp},
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      source = """
      import urllib.request

      allowed = urllib.request.urlopen("http://host.docker.internal:#{port}", timeout=5).read().decode()
      print("allowed=" + allowed)

      model = urllib.request.urlopen("http://host.docker.internal:#{model_port}", timeout=5).read().decode()
      print("model=" + model)

      try:
          urllib.request.urlopen("https://example.com", timeout=3).read()
      except Exception:
          print("public_denied=ok")
      else:
          print("public_denied=fail")

      try:
          urllib.request.urlopen("http://host.docker.internal:#{denied_port}", timeout=3).read()
      except Exception:
          print("host_port_denied=ok")
      else:
          print("host_port_denied=fail")
      """

      assert {:ok, result} =
               LitterBox.exec(
                 [sandbox: :local_code, runtime: :python, source: source, network: :restricted],
                 profile: profile
               )

      assert result.status == :pass
      assert result.stdout =~ "allowed=mcp-ok"
      assert result.stdout =~ "model=model-ok"
      assert result.stdout =~ "public_denied=ok"
      assert result.stdout =~ "host_port_denied=ok"
      assert result.metadata.effective_network.restricted_egress?
      refute docker_resource_names("runic-sandbox-egress-") |> Enum.any?()
    end
  end

  test "docker restricted egress works for live attach and cleans sidecars" do
    if docker_image_available?() do
      {:ok, server} = start_mcp_http_server("attach-mcp-ok")
      {:ok, port} = :inet.port(server)

      assert {:ok, profile} =
               Profile.new(
                 name: :local_code,
                 backend: :docker,
                 runtimes: [:python],
                 network: :restricted,
                 egress_allowlist: [
                   %{scheme: "http", host: "host.docker.internal", port: port, purpose: :mcp}
                 ],
                 mcp_boundary: %{transport: :egress_allowlist, purpose: :mcp},
                 image: "runic-ai/sandbox:elixir-python-node"
               )

      assert {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)

      source = """
      import urllib.request
      print(urllib.request.urlopen("http://host.docker.internal:#{port}", timeout=5).read().decode(), end="")
      """

      assert {:ok, handle} =
               LitterBox.attach(session,
                 runtime: :python,
                 source: source,
                 network: :restricted
               )

      events = Enum.to_list(handle.events)
      assert stdout_from_events(events) == "attach-mcp-ok"
      assert List.last(events).payload.status == :pass
      assert List.first(events).payload.effective_network.restricted_egress?

      assert :ok = LitterBox.close_attach(handle)
      assert :ok = LitterBox.close_session(session)
      refute docker_resource_names("runic-sandbox-egress-") |> Enum.any?()
    end
  end

  test "vmsan CLI builds argv and parses JSON events" do
    assert VmsanCLI.command(["exec", "vm-1", "echo", "ok"], executable: "/usr/bin/vmsan") ==
             {"/usr/bin/vmsan", ["--json", "exec", "vm-1", "echo", "ok"]}

    assert VmsanCLI.command(["create"], executable: "vmsan", sudo?: true, path: "/bin") ==
             {"sudo", ["-n", "env", "PATH=/bin", "vmsan", "--json", "create"]}

    assert VmsanCLI.command(["exec", "vm-1"], executable: "/usr/bin/vmsan", json?: false) ==
             {"/usr/bin/vmsan", ["exec", "vm-1"]}

    assert VmsanCLI.create_args(
             vcpus: 2,
             memory: 512,
             runtime: :base,
             network_policy: "deny-all",
             allowed_domains: ["hex.pm", "github.com"]
           ) == [
             "create",
             "--vcpus",
             "2",
             "--memory",
             "512",
             "--runtime",
             "base",
             "--network-policy",
             "deny-all",
             "--allowed-domain",
             "hex.pm,github.com"
           ]

    assert VmsanCLI.exec_args("vm-1", ["sh", "-lc", "echo ok"], workdir: "/workspace") ==
             ["exec", "--workdir", "/workspace", "vm-1", "--", "sh", "-lc", "echo ok"]

    assert VmsanCLI.exec_interactive_args("vm-1", ["sh"], workdir: "/workspace") == [
             "exec",
             "--interactive",
             "--workdir",
             "/workspace",
             "vm-1",
             "--",
             "sh"
           ]

    runner = fn "vmsan", ["--json", "exec", "vm-1", "echo", "ok"], _opts ->
      {"ok\n{\"path\":\"exec\",\"vmId\":\"vm-1\"}\n", 0}
    end

    assert {:ok, result} =
             VmsanCLI.run_json(["exec", "vm-1", "echo", "ok"], runner: runner)

    assert result.stream_output == "ok\n"
    assert result.event["path"] == "exec"

    error_runner = fn "vmsan", ["--json", "exec", "missing-vm", "echo", "ok"], _opts ->
      {Jason.encode!(%{
         path: "exec",
         error: %{
           message: "VM not found: missing-vm",
           code: "ERR_VM_NOT_FOUND",
           fix: "Run 'vmsan list' to see available VMs."
         }
       }), 1}
    end

    assert {:error, error} =
             VmsanCLI.run_json(["exec", "missing-vm", "echo", "ok"], runner: error_runner)

    assert error.message == "VM not found: missing-vm"
    assert error.details.code == "ERR_VM_NOT_FOUND"

    nonzero_runner = fn "vmsan", ["--json", "exec", "vm-1", "false"], _opts ->
      {Jason.encode!(%{path: "exec", vmId: "vm-1"}), 1}
    end

    assert {:error, nonzero_error} =
             VmsanCLI.run_json(["exec", "vm-1", "false"], runner: nonzero_runner)

    assert nonzero_error.message == "vmsan command failed"
    assert nonzero_error.details.exit_status == 1

    sudo_password_runner = fn
      "sudo", ["-n", "env", "PATH=/bin", "vmsan", "--json", "create"], _opts ->
        {"sudo: a password is required\n", 1}
    end

    assert {:error, sudo_error} =
             VmsanCLI.run_json(["create"],
               runner: sudo_password_runner,
               sudo?: true,
               path: "/bin"
             )

    assert sudo_error.kind == :provider
    assert sudo_error.message == "vmsan command requires passwordless sudo"
    assert sudo_error.details.exit_status == 1
  end

  test "vmsan backend reports doctor diagnostics and blocks execution when unavailable" do
    commands = fn
      "sh", ["-c", "command -v vmsan"], _opts ->
        {"/usr/bin/vmsan\n", 0}

      "/usr/bin/vmsan", ["doctor", "--json"], _opts ->
        {Jason.encode!(vmsan_doctor_fixture()), 1}

      "/usr/bin/vmsan", ["--version"], _opts ->
        {"0.3.0\n", 0}

      _command, _args, _opts ->
        {"", 1}
    end

    assert {:ok, profile} =
             Profile.new(
               name: :local_code,
               backend: :vmsan,
               runtimes: [:bash],
               network: :disabled
             )

    assert {:ok, status} = LitterBox.status(profile: profile, commands: commands)

    assert [%{name: :vmsan, isolation_level: :microvm, security_boundary?: true} = health] =
             status.backends

    refute health.available?
    assert health.capabilities.session_files?
    assert health.capabilities.checkpoints?

    assert %{requirement: :firecracker} in Enum.map(
             health.missing_requirements,
             &Map.take(&1, [:requirement])
           )

    assert {:error, error} =
             LitterBox.open_session(:local_code, [], profile: profile, commands: commands)

    assert error.message == "vmsan sandbox provider is not available for execution"
    assert Enum.any?(error.details.missing_requirements, &(&1.requirement == :kernel_image))
  end

  test "vmsan backend performs mocked create upload exec snapshot restore and cleanup lifecycle" do
    agent_pid = self()

    commands = fn
      "sh", ["-c", "command -v vmsan"], _opts ->
        {"/usr/bin/vmsan\n", 0}

      "/usr/bin/vmsan", ["doctor", "--json"], _opts ->
        {Jason.encode!(vmsan_healthy_doctor_fixture()), 0}

      "/usr/bin/vmsan", ["--version"], _opts ->
        {"0.3.0\n", 0}

      "sudo",
      ["-n", "env", "PATH=" <> _path, "/usr/bin/vmsan", "--json", "create" | _args],
      _opts ->
        send(agent_pid, {:vmsan_create, :sudo})
        {Jason.encode!(%{"path" => "create", "vmId" => "vm-a"}), 0}

      "/usr/bin/vmsan",
      [
        "--json",
        "exec",
        "--sudo",
        "vm-a",
        "--",
        "sh",
        "-lc",
        "mkdir -p -- '/workspace' && chown ubuntu:ubuntu -- '/workspace'"
      ],
      _opts ->
        send(agent_pid, :vmsan_prepare_workspace)
        {Jason.encode!(%{"path" => "exec", "vmId" => "vm-a"}), 0}

      "/usr/bin/vmsan", ["--json", "upload", "--dest", "/workspace", "vm-a", local_path], _opts ->
        send(agent_pid, {:vmsan_upload, local_path})
        {Jason.encode!(%{"path" => "upload", "vmId" => "vm-a"}), 0}

      "/usr/bin/vmsan",
      [
        "--json",
        "exec",
        "--workdir",
        "/workspace",
        "vm-a",
        "--",
        "sh",
        "-lc",
        "cat /workspace/in.txt"
      ],
      _opts ->
        send(agent_pid, :vmsan_exec)
        {"hello\n" <> Jason.encode!(%{"path" => "exec", "vmId" => "vm-a"}) <> "\n", 0}

      "/usr/bin/vmsan",
      ["--json", "exec", "vm-a", "--", "sh", "-lc", "ps -eo pid=,stat=,comm= 2>/dev/null || true"],
      _opts ->
        send(agent_pid, :vmsan_ps)
        {"222 S sh\n" <> Jason.encode!(%{"path" => "exec", "vmId" => "vm-a"}) <> "\n", 0}

      "/usr/bin/vmsan",
      ["--json", "exec", "vm-a", "--", "sh", "-lc", "cat " <> _pidfile],
      _opts ->
        send(agent_pid, :vmsan_pidfile)
        {"222\n" <> Jason.encode!(%{"path" => "exec", "vmId" => "vm-a"}) <> "\n", 0}

      "/usr/bin/vmsan",
      ["--json", "exec", "vm-a", "--", "sh", "-lc", "ps -p '222' " <> _rest],
      _opts ->
        send(agent_pid, :vmsan_ps_pid)
        {"222 S sh\n" <> Jason.encode!(%{"path" => "exec", "vmId" => "vm-a"}) <> "\n", 0}

      "/usr/bin/vmsan",
      ["--json", "exec", "vm-a", "--", "sh", "-lc", "kill -s 'TERM' '222'"],
      _opts ->
        send(agent_pid, :vmsan_kill)
        {Jason.encode!(%{"path" => "exec", "vmId" => "vm-a"}) <> "\n", 0}

      "sudo",
      ["-n", "env", "PATH=" <> _path, "/usr/bin/vmsan", "--json", "snapshot", "create", "vm-a"],
      _opts ->
        send(agent_pid, {:vmsan_snapshot, :sudo})

        {Jason.encode!(%{
           "path" => "snapshot.create",
           "vmId" => "vm-a",
           "snapshotId" => "snap-a"
         }), 0}

      "sudo",
      ["-n", "env", "PATH=" <> _path, "/usr/bin/vmsan", "--json", "remove", "--force", "vm-a"],
      _opts ->
        send(agent_pid, {:vmsan_remove, :sudo})
        {Jason.encode!(%{"path" => "remove", "vmId" => "vm-a"}), 0}

      command, args, _opts ->
        send(agent_pid, {:vmsan_unmatched, command, args})
        {"", 1}
    end

    port_open = fn args, opts ->
      send(agent_pid, {:vmsan_process_port, args, Keyword.take(opts, [:executable, :sudo?])})

      port =
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: ["-c", "printf process-live"]
        ])

      {:ok, port}
    end

    assert {:ok, profile} =
             Profile.new(
               name: :local_code,
               backend: :vmsan,
               runtimes: [:bash],
               network: :disabled,
               backend_options: %{sudo?: true, executable: "/usr/bin/vmsan"}
             )

    assert {:ok, session} =
             LitterBox.open_session(:local_code, [],
               profile: profile,
               commands: commands,
               runner: commands
             )

    assert_receive {:vmsan_create, :sudo}
    assert_receive :vmsan_prepare_workspace
    assert session.metadata.sudo?
    assert File.dir?(session.metadata.transfer_root)

    assert {:ok, result} =
             LitterBox.exec(
               session,
               [
                 runtime: :bash,
                 source: "cat /workspace/in.txt",
                 files: %{"in.txt" => "hello"},
                 timeout_ms: 1_234
               ],
               commands: commands,
               runner: commands
             )

    assert result.status == :pass
    assert result.stdout == "hello\n"
    assert_receive {:vmsan_upload, local_path}
    assert File.read!(local_path) == "hello"
    assert_receive :vmsan_exec

    assert session.capabilities.streaming?

    assert {:ok, handle} =
             LitterBox.attach(
               session,
               [
                 runtime: :bash,
                 source: "cat /workspace/in.txt",
                 files: %{"in.txt" => "hello"}
               ],
               commands: commands,
               runner: commands
             )

    assert handle.metadata.streaming_live? == false
    assert handle.metadata.provider_transport == :vmsan_cli
    assert attach_event_types(handle) == [:exec_started, :stdout_chunk, :exec_finished]
    assert attach_stdout(handle) == "hello\n"
    assert_receive {:vmsan_upload, _local_path}
    assert_receive :vmsan_exec

    assert Capabilities.process_host?(session.capabilities)
    assert Capabilities.live_process_stream?(session.capabilities)

    assert {:ok, process} =
             LitterBox.start_process(
               session,
               [
                 runtime: :bash,
                 source: "printf process-live",
                 timeout_ms: 1_234
               ],
               commands: commands,
               runner: commands,
               port_open: port_open
             )

    assert process.metadata.provider_transport == :vmsan_cli
    assert process.metadata.streaming_live?
    assert_receive {:vmsan_process_port, process_args, process_opts}
    assert "exec" in process_args
    assert "--interactive" in process_args
    assert Map.new(process_opts) == %{executable: "/usr/bin/vmsan", sudo?: false}

    assert {:ok, process_event_stream} = LitterBox.process_events(process)
    process_events = Enum.to_list(process_event_stream)

    assert [:process_started, :stdout_chunk, :process_finished] =
             Enum.map(process_events, & &1.type)

    assert Enum.any?(process_events, &(&1.payload[:chunk] == "process-live"))

    assert {:ok, waited_process} =
             LitterBox.start_process(
               session,
               [
                 runtime: :bash,
                 source: "printf process-live"
               ],
               commands: commands,
               runner: commands,
               port_open: port_open
             )

    assert_receive {:vmsan_process_port, _wait_args, _wait_opts}
    assert {:ok, waited} = LitterBox.wait_process(waited_process)
    assert waited.status == :exited
    assert waited.exit_status == 0

    assert {:ok, [listed_process]} =
             LitterBox.list_processes(session, commands: commands, runner: commands)

    assert listed_process.pid == 222
    assert listed_process.status == :running
    assert_receive :vmsan_ps

    assert {:ok, status} =
             LitterBox.process_status(session, process, commands: commands, runner: commands)

    assert status.status == :running
    assert_receive :vmsan_pidfile
    assert_receive :vmsan_ps_pid

    assert :ok = LitterBox.kill_process(process, commands: commands, runner: commands)
    assert_receive :vmsan_pidfile
    assert_receive :vmsan_kill

    assert {:error, escape_error} =
             LitterBox.exec(
               session,
               [
                 runtime: :bash,
                 source: "true",
                 files: %{"../escape.txt" => "nope"}
               ],
               commands: commands,
               runner: commands
             )

    assert escape_error.message == "vmsan inline file path escapes the request cwd"

    assert {:error, absolute_error} =
             LitterBox.exec(
               session,
               [
                 runtime: :bash,
                 source: "true",
                 files: %{"/etc/passwd" => "nope"}
               ],
               commands: commands,
               runner: commands
             )

    assert absolute_error.message ==
             "vmsan inline file path must be relative to the request cwd"

    assert {:ok, checkpoint} =
             LitterBox.checkpoint(session, %{}, commands: commands, runner: commands)

    assert checkpoint.id == "snap-a"
    assert checkpoint.metadata.kind == :microvm_snapshot
    assert checkpoint.metadata.preserves.process_memory
    assert checkpoint.metadata.preserves.running_processes
    refute checkpoint.metadata.preserves.tcp_connections
    assert_receive {:vmsan_snapshot, :sudo}

    assert :ok = LitterBox.close_session(session, commands: commands, runner: commands)
    refute File.exists?(session.metadata.transfer_root)
    assert_receive {:vmsan_remove, :sudo}
  end

  test "vmsan one-shot execution reports cleanup failure after successful exec" do
    agent_pid = self()

    commands = fn
      "sh", ["-c", "command -v vmsan"], _opts ->
        {"/usr/bin/vmsan\n", 0}

      "/usr/bin/vmsan", ["doctor", "--json"], _opts ->
        {Jason.encode!(vmsan_healthy_doctor_fixture()), 0}

      "/usr/bin/vmsan", ["--version"], _opts ->
        {"0.3.0\n", 0}

      "sudo",
      ["-n", "env", "PATH=" <> _path, "/usr/bin/vmsan", "--json", "create" | _args],
      _opts ->
        {Jason.encode!(%{"path" => "create", "vmId" => "vm-cleanup"}), 0}

      "/usr/bin/vmsan",
      [
        "--json",
        "exec",
        "--sudo",
        "vm-cleanup",
        "--",
        "sh",
        "-lc",
        "mkdir -p -- '/workspace' && chown ubuntu:ubuntu -- '/workspace'"
      ],
      _opts ->
        {Jason.encode!(%{"path" => "exec", "vmId" => "vm-cleanup"}), 0}

      "/usr/bin/vmsan",
      [
        "--json",
        "exec",
        "--workdir",
        "/workspace",
        "vm-cleanup",
        "--",
        "sh",
        "-lc",
        "echo ok"
      ],
      _opts ->
        {"ok\n" <> Jason.encode!(%{"path" => "exec", "vmId" => "vm-cleanup"}) <> "\n", 0}

      "sudo",
      [
        "-n",
        "env",
        "PATH=" <> _path,
        "/usr/bin/vmsan",
        "--json",
        "remove",
        "--force",
        "vm-cleanup"
      ],
      _opts ->
        send(agent_pid, :cleanup_attempted)

        {Jason.encode!(%{
           "path" => "remove",
           "error" => %{"message" => "remove failed", "code" => "ERR_REMOVE"}
         }), 1}

      _command, _args, _opts ->
        {"", 1}
    end

    profile =
      Profile.new!(
        name: :local_code,
        backend: :vmsan,
        runtimes: [:bash],
        network: :disabled,
        backend_options: %{sudo?: true, executable: "/usr/bin/vmsan"}
      )

    assert {:ok, instance} = LitterBox.Backends.Vmsan.provision(profile, commands: commands)

    request =
      ExecutionRequest.new!(
        sandbox: :local_code,
        runtime: :bash,
        source: "echo ok",
        timeout_ms: 1_234
      )

    assert {:error, error} =
             LitterBox.Backends.Vmsan.exec(instance, request,
               commands: commands,
               runner: commands
             )

    assert error.message == "vmsan one-shot cleanup failed"
    assert error.details.execution_result.stdout == "ok\n"
    assert error.details.cleanup_error.message == "remove failed"
    assert_receive :cleanup_attempted
  end

  test "sprites backend reports redacted status and exercises mocked stateful API lifecycle" do
    parent = self()

    requester = fn
      :post, _config, "/v1/sprites", %{}, body, opts ->
        send(
          parent,
          {:sprites_request, :create, Jason.decode!(body), Keyword.get(opts, :headers)}
        )

        {:ok,
         %{
           status: 201,
           body:
             Jason.encode!(%{
               id: "sprite-id-1",
               name: "runic-test-sprite",
               organization: "runic",
               status: "cold",
               url: "https://runic-test.sprites.app"
             })
         }}

      :put, _config, "/v1/sprites/runic-test-sprite/fs/write", query, contents, opts ->
        send(parent, {:sprites_request, :write, query, contents, Keyword.get(opts, :headers)})
        {:ok, %{status: 200, body: Jason.encode!(%{path: query.path, size: byte_size(contents)})}}

      :post, _config, "/v1/sprites/runic-test-sprite/exec", query, stdin, _opts ->
        send(parent, {:sprites_request, :exec, query, stdin})

        {:ok,
         %{
           status: 200,
           body: Jason.encode!(%{stdout: "sprite-ok\n", stderr: "", exit_code: 0})
         }}

      :get, _config, "/v1/sprites/runic-test-sprite/exec", %{}, "", _opts ->
        send(parent, {:sprites_request, :exec_list})

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!([
               %{
                 id: "exec-1",
                 command: "sh -lc sleep",
                 is_active: true,
                 tty: false,
                 created: "2026-05-31T00:00:00Z"
               }
             ])
         }}

      :post,
      _config,
      "/v1/sprites/runic-test-sprite/exec/exec-1/kill",
      %{signal: "SIGTERM"},
      "",
      _opts ->
        send(parent, {:sprites_request, :exec_kill})

        {:ok,
         %{
           status: 200,
           body:
             [
               Jason.encode!(%{type: "signal", pid: 42, signal: "SIGTERM"}),
               Jason.encode!(%{type: "complete", exit_code: 0})
             ]
             |> Enum.join("\n")
         }}

      :get, _config, "/v1/sprites/runic-test-sprite/fs/read", query, "", _opts ->
        send(parent, {:sprites_request, :read, query})
        {:ok, %{status: 200, body: "sprite-file"}}

      :get, _config, "/v1/sprites/runic-test-sprite/fs/list", query, "", _opts ->
        send(parent, {:sprites_request, :list_files, query})

        {:ok,
         %{
           status: 200,
           body: Jason.encode!(%{entries: [%{name: "out.txt", type: "file", size: 11}]})
         }}

      :post, _config, "/v1/sprites/runic-test-sprite/checkpoint", %{}, body, _opts ->
        send(parent, {:sprites_request, :checkpoint, Jason.decode!(body)})

        {:ok,
         %{
           status: 200,
           body:
             [
               Jason.encode!(%{type: "info", data: "Creating checkpoint..."}),
               Jason.encode!(%{type: "complete", data: "Checkpoint v2 created successfully"})
             ]
             |> Enum.join("\n")
         }}

      :post, _config, "/v1/sprites/runic-test-sprite/checkpoints/v2/restore", %{}, "", _opts ->
        send(parent, {:sprites_request, :restore})
        {:ok, %{status: 200, body: Jason.encode!(%{ok: true})}}

      :post, _config, "/v1/sprites/runic-test-sprite/services", %{}, body, _opts ->
        send(parent, {:sprites_request, :service_create, Jason.decode!(body)})

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               name: "web",
               cmd: "python",
               args: ["-m", "http.server", "8000"],
               http_port: 8000,
               state: %{status: "running", pid: 42}
             })
         }}

      :get, _config, "/v1/sprites/runic-test-sprite/services", %{}, "", _opts ->
        send(parent, {:sprites_request, :services_list})

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!([
               %{name: "web", cmd: "python", http_port: 8000, state: %{status: "running"}}
             ])
         }}

      :post, _config, "/v1/sprites/runic-test-sprite/services/web/stop", %{}, "", _opts ->
        send(parent, {:sprites_request, :service_stop})
        {:ok, %{status: 200, body: Jason.encode!(%{ok: true})}}

      :delete, _config, "/v1/sprites/runic-test-sprite", %{}, "", _opts ->
        send(parent, {:sprites_request, :delete})
        {:ok, %{status: 204}}
    end

    env = fn
      "SPRITES_TOKEN" -> "secret-token"
      _name -> nil
    end

    websocket_open = fn config, url, query, opts ->
      send(parent, {:sprites_websocket, config, url, query, Keyword.get(opts, :headers)})

      {:ok,
       %{
         session_id: "exec-1",
         events: [<<1, "process-live">>, <<3, 0>>],
         stdin: fn input ->
           send(parent, {:sprites_stdin, input})
           :ok
         end,
         stdin_eof: fn ->
           send(parent, :sprites_stdin_eof)
           :ok
         end,
         closer: fn ->
           send(parent, :sprites_process_close)
           :ok
         end
       }}
    end

    assert {:ok, profile} =
             Profile.new(
               name: :sprites_code,
               backend: :sprites,
               runtimes: [:bash, :python],
               network: :restricted,
               backend_options: %{
                 sprite: "runic-test-sprite",
                 organization: "runic",
                 create_policy: :ephemeral
               }
             )

    assert {:ok, status} = LitterBox.status(profile: profile, env: env)
    assert [%{name: :sprites, capabilities: capabilities} = health] = status.backends
    assert health.available?
    assert health.token_env == "SPRITES_TOKEN"
    assert health.token_value == :redacted
    assert health.process_transport.native == :sprites_websocket_exec
    assert health.process_transport.default_adapter == :websocat
    assert capabilities.session_files?
    assert capabilities.checkpoints?
    assert capabilities.services?
    assert capabilities.proxy?
    assert Capabilities.state_tier(capabilities) == :service_actor
    assert Capabilities.workspace_persistent?(capabilities)
    assert Capabilities.service_host?(capabilities)
    assert Capabilities.process_host?(capabilities)
    assert Capabilities.live_process_stream?(capabilities)
    assert Capabilities.snapshot_modes(capabilities) == [:provider_checkpoint]
    refute inspect(status) =~ "secret-token"

    assert {:ok, session} =
             LitterBox.open_session(:sprites_code, [],
               profile: profile,
               env: env,
               requester: requester
             )

    assert session.backend == :sprites
    assert session.state_model == :service_actor
    assert session.transport_model == :remote_microvm
    assert session.metadata.token_env == "SPRITES_TOKEN"
    assert session.metadata.default_cwd == "/home/sprite"
    assert Capabilities.default_cwd(session.capabilities) == "/home/sprite"
    assert Capabilities.state_tier(session.capabilities) == :service_actor
    assert Capabilities.service_host?(session.capabilities)
    assert Capabilities.process_host?(session.capabilities)
    assert Capabilities.live_process_stream?(session.capabilities)
    refute inspect(session) =~ "secret-token"
    assert_receive {:sprites_request, :create, %{"name" => "runic-test-sprite"}, headers}
    assert inspect(headers) =~ "secret-token"

    assert {:ok, result} =
             LitterBox.exec(
               session,
               [
                 runtime: :bash,
                 source: "cat in.txt",
                 files: %{"in.txt" => "sprite-file"}
               ],
               env: env,
               requester: requester
             )

    assert result.status == :pass
    assert result.stdout == "sprite-ok\n"
    assert result.metadata.provider == :sprites

    assert_receive {:sprites_request, :write, %{path: "in.txt", workingDir: "/home/sprite"},
                    "sprite-file", _write_headers}

    assert_receive {:sprites_request, :exec, %{cmd: ["sh", "-lc", "cat in.txt"]}, ""}

    assert session.capabilities.streaming?

    assert {:ok, handle} =
             LitterBox.attach(
               session,
               [
                 runtime: :bash,
                 source: "cat in.txt",
                 files: %{"in.txt" => "sprite-file"}
               ],
               env: env,
               requester: requester
             )

    assert handle.metadata.streaming_live? == false
    assert handle.metadata.provider_transport == :sprites_http_exec
    assert attach_event_types(handle) == [:exec_started, :stdout_chunk, :exec_finished]
    assert attach_stdout(handle) == "sprite-ok\n"

    assert_receive {:sprites_request, :write, %{path: "in.txt", workingDir: "/home/sprite"},
                    "sprite-file", _write_headers}

    assert_receive {:sprites_request, :exec, %{cmd: ["sh", "-lc", "cat in.txt"]}, ""}

    assert {:ok, process} =
             LitterBox.start_process(
               session,
               [runtime: :bash, source: "printf process-live"],
               env: env,
               websocket_open: websocket_open
             )

    assert process.id == "exec-1"
    assert process.metadata.provider_transport == :sprites_websocket_exec
    assert process.metadata.streaming_live?

    assert_receive {:sprites_websocket, %{api_url: "https://api.sprites.dev"},
                    "wss://api.sprites.dev/v1/sprites/runic-test-sprite/exec" <> _query_string,
                    %{cmd: ["sh", "-lc", "printf process-live"], stdin: true}, websocket_headers}

    assert inspect(websocket_headers) =~ "secret-token"

    assert :ok = LitterBox.write_process_stdin(process, "hello\n")
    assert_receive {:sprites_stdin, "hello\n"}
    assert :ok = LitterBox.close_process_stdin(process)
    assert_receive :sprites_stdin_eof

    assert {:ok, process_event_stream} = LitterBox.process_events(process)
    process_events = Enum.to_list(process_event_stream)

    assert [:process_started, :stdout_chunk, :process_finished] =
             Enum.map(process_events, & &1.type)

    assert Enum.any?(process_events, &(&1.payload[:chunk] == "process-live"))

    assert {:ok, [listed_process]} =
             LitterBox.list_processes(session, env: env, requester: requester)

    assert listed_process.id == "exec-1"
    assert listed_process.status == :running
    assert_receive {:sprites_request, :exec_list}

    assert {:ok, status} =
             LitterBox.process_status(session, process, env: env, requester: requester)

    assert status.id == "exec-1"
    assert status.status == :running
    assert_receive {:sprites_request, :exec_list}

    assert {:ok, waited_process} =
             LitterBox.start_process(
               session,
               [runtime: :bash, source: "printf process-live"],
               env: env,
               websocket_open: websocket_open
             )

    assert_receive {:sprites_websocket, _config, _url, _query, _headers}
    assert {:ok, waited} = LitterBox.wait_process(waited_process)
    assert waited.status == :exited
    assert waited.exit_status == 0

    assert :ok = LitterBox.kill_process(process, env: env, requester: requester)
    assert_receive {:sprites_request, :exec_kill}
    assert_receive :sprites_process_close

    assert {:ok, "sprite-file"} =
             LitterBox.read_file(session, "/workspace/in.txt", env: env, requester: requester)

    assert_receive {:sprites_request, :read, %{path: "/workspace/in.txt"}}

    assert {:ok, [file]} =
             LitterBox.list_files(session, "/workspace", env: env, requester: requester)

    assert file.path == "out.txt"
    assert file.bytes == 11
    assert_receive {:sprites_request, :list_files, %{path: "/workspace"}}

    assert {:ok, checkpoint} =
             LitterBox.checkpoint(session, %{comment: "before"},
               env: env,
               requester: requester
             )

    assert checkpoint.id == "v2"
    assert checkpoint.metadata.kind == :provider_checkpoint
    assert checkpoint.metadata.preserves.running_service_state == :provider_dependent
    assert checkpoint.metadata.preserves.process_memory == :provider_dependent
    assert_receive {:sprites_request, :checkpoint, %{"comment" => "before"}}

    assert {:ok, ^session} =
             LitterBox.restore(session, checkpoint, env: env, requester: requester)

    assert_receive {:sprites_request, :restore}

    assert {:ok, service} =
             LitterBox.start_service(
               session,
               [name: "web", cmd: "python", args: ["-m", "http.server", "8000"], http_port: 8000],
               env: env,
               requester: requester
             )

    assert service.name == "web"
    assert service.status == :running
    assert_receive {:sprites_request, :service_create, %{"name" => "web"}}

    assert {:ok, [listed_service]} =
             LitterBox.list_services(session, env: env, requester: requester)

    assert listed_service.name == "web"
    assert_receive {:sprites_request, :services_list}

    assert {:ok, proxy} = LitterBox.open_proxy(session, service)
    assert proxy.backend == :sprites
    assert proxy.url =~ "/v1/sprites/runic-test-sprite/proxy"
    assert proxy.metadata.protocol == :websocket_tcp_proxy

    assert :ok = LitterBox.stop_service(session, service, env: env, requester: requester)
    assert_receive {:sprites_request, :service_stop}

    assert :ok = LitterBox.close_session(session, env: env, requester: requester)
    assert_receive {:sprites_request, :delete}
  end

  test "sprites direct exec forwards adapter opts and honors ephemeral lifecycle" do
    parent = self()

    requester = fn
      :post, _config, "/v1/sprites", %{}, body, opts ->
        send(parent, {:sprites_direct, :create, Jason.decode!(body), Keyword.get(opts, :headers)})
        {:ok, %{status: 201, body: Jason.encode!(%{id: "sprite-id-1", name: "runic-direct"})}}

      :post, _config, "/v1/sprites/runic-direct/exec", query, "", _opts ->
        send(parent, {:sprites_direct, :exec, query})
        {:ok, %{status: 200, body: <<1, "direct-ok\n", 3, 0>>}}

      :delete, _config, "/v1/sprites/runic-direct", %{}, "", _opts ->
        send(parent, {:sprites_direct, :delete})
        {:ok, %{status: 204}}
    end

    env = fn
      "SPRITES_TOKEN" -> "secret-token"
      _name -> nil
    end

    assert {:ok, profile} =
             Profile.new(
               name: :sprites_code,
               backend: :sprites,
               runtimes: [:bash],
               network: :restricted,
               backend_options: %{sprite: "runic-direct", create_policy: :ephemeral}
             )

    assert {:ok, result} =
             LitterBox.exec(
               [sandbox: :sprites_code, runtime: :bash, source: "echo direct-ok"],
               profile: profile,
               env: env,
               requester: requester
             )

    assert result.status == :pass
    assert result.stdout == "direct-ok\n"
    assert_receive {:sprites_direct, :create, %{"name" => "runic-direct"}, headers}
    assert inspect(headers) =~ "secret-token"
    assert_receive {:sprites_direct, :exec, %{cmd: ["sh", "-lc", "echo direct-ok"]}}
    assert_receive {:sprites_direct, :delete}
  end

  test "sprites terminal adapter decodes multiple binary exec frames" do
    requester = fn
      :post, _config, "/v1/sprites/runic-binary/exec", query, "", _opts ->
        send(self(), {:sprites_binary_exec, query})
        {:ok, %{status: 200, body: <<1, "sprite-", 1, "binary", 2, "warn", 3, 0>>}}
    end

    env = fn
      "SPRITES_TOKEN" -> "secret-token"
      _name -> nil
    end

    assert {:ok, profile} =
             Profile.new(
               name: :sprites_code,
               backend: :sprites,
               runtimes: [:bash],
               network: :restricted,
               backend_options: %{sprite: "runic-binary", create_policy: :use_existing}
             )

    assert {:ok, session} =
             LitterBox.open_session(:sprites_code, [],
               profile: profile,
               env: env,
               requester: requester
             )

    assert {:ok, handle} =
             LitterBox.attach(
               session,
               [runtime: :bash, source: "printf sprite-binary"],
               env: env,
               requester: requester
             )

    summary = AttachBridge.summarize(handle)
    assert summary.status == :pass
    assert summary.stdout == "sprite-binary"
    assert summary.stderr == "warn"

    assert attach_event_types(handle) == [
             :exec_started,
             :stdout_chunk,
             :stderr_chunk,
             :exec_finished
           ]
  end

  test "sprites exec returns structured error for malformed provider exit status" do
    requester = fn
      :post, _config, "/v1/sprites/runic-status/exec", _query, "", _opts ->
        {:ok, %{status: 200, body: Jason.encode!(%{stdout: "ok\n", exit_status: "unknown"})}}
    end

    env = fn
      "SPRITES_TOKEN" -> "secret-token"
      _name -> nil
    end

    assert {:ok, profile} =
             Profile.new(
               name: :sprites_code,
               backend: :sprites,
               runtimes: [:bash],
               network: :restricted,
               backend_options: %{sprite: "runic-status", create_policy: :use_existing}
             )

    assert {:ok, session} =
             LitterBox.open_session(:sprites_code, [], profile: profile, env: env)

    assert {:error, error} =
             LitterBox.exec(session, [runtime: :bash, source: "echo ok"],
               env: env,
               requester: requester
             )

    assert error.message == "invalid sprites exec exit status"
    assert error.details.exit_status == "unknown"
  end

  test "sprites exec decodes nonzero binary stream frames" do
    requester = fn
      :post, _config, "/v1/sprites/runic-status/exec", _query, "", _opts ->
        {:ok, %{status: 200, body: <<2, "boom\n", 3, 7>>}}
    end

    env = fn
      "SPRITES_TOKEN" -> "secret-token"
      _name -> nil
    end

    assert {:ok, profile} =
             Profile.new(
               name: :sprites_code,
               backend: :sprites,
               runtimes: [:bash],
               network: :restricted,
               backend_options: %{sprite: "runic-status", create_policy: :use_existing}
             )

    assert {:ok, session} =
             LitterBox.open_session(:sprites_code, [], profile: profile, env: env)

    assert {:ok, result} =
             LitterBox.exec(session, [runtime: :bash, source: "echo no", cwd: "/home/sprite"],
               env: env,
               requester: requester
             )

    assert result.status == :fail
    assert result.stdout == ""
    assert result.stderr == "boom\n"
    assert result.exit_status == 7
  end

  test "reports expose health matrix, latency, security posture, and publication strategy" do
    health =
      LitterBox.Reports.health_matrix([
        [name: :just_bash, backend: :just_bash, runtimes: [:bash], network: :disabled],
        [
          name: :remote_fly,
          backend: :remote,
          runtimes: [:bash],
          network: :restricted,
          backend_options: [
            provider: :fly_machines,
            app: "runic-sandbox-test",
            machine_id: "machine-test-id",
            executable: "runic-sandbox-missing-flyctl"
          ]
        ]
      ])

    assert %{host: %{os_family: _}, rows: [just_bash, remote]} = health
    assert just_bash.backend == :just_bash
    assert just_bash.isolation_level == :in_process_virtual
    assert just_bash.transport_model == :in_process
    assert just_bash.state_model == :one_shot
    assert just_bash.capabilities.exec?
    assert remote.backend == :remote
    assert remote.health.provider == :fly_machines
    assert remote.transport_model == :provider_cli
    assert Enum.any?(remote.missing_requirements, &(&1.requirement == :fly_cli))

    latency =
      LitterBox.Reports.latency_report([
        [name: :just_bash, backend: :just_bash, runtimes: [:bash], network: :disabled]
      ])

    assert [
             %{
               backend: :just_bash,
               status: %{status: :ok},
               cold_exec: %{status: :ok},
               warm_exec: %{status: :ok},
               session_open: %{status: :ok},
               session_exec: %{status: :ok},
               session_checkpoint: %{status: :error},
               session_restore: %{status: :skipped},
               session_close: %{status: :ok},
               snapshot: %{status: :ok},
               reset: %{status: :ok}
             }
           ] = latency.rows

    security = LitterBox.Reports.security_posture()
    assert Enum.any?(security.rows, &(&1.backend == :docker and &1.security_boundary?))

    strategy = LitterBox.Reports.publication_strategy()
    assert strategy.base_package.required_dependencies == [:jason]
    assert :just_bash in strategy.base_package.optional_dependencies
    assert Enum.any?(strategy.split_later, &(&1.app == :litter_box_vmsan))
  end

  test "host probe parses vmsan doctor failures into missing requirements" do
    output = Jason.encode!(vmsan_doctor_fixture())

    doctor = HostProbe.parse_vmsan_doctor(output, executable: "/usr/bin/vmsan")

    refute doctor.available?
    assert doctor.summary == %{passed: 5, failed: 8, total: 13}

    requirements = Enum.map(doctor.missing_requirements, & &1.requirement)
    assert :firecracker in requirements
    assert :jailer in requirements
    assert :vmsan_agent in requirements
    assert :vmsan_nftables in requirements
    assert :kernel_image in requirements
    assert :rootfs_image in requirements
    assert :nftables_kernel in requirements
  end

  test "host probe redacts sprite token and reports provider readiness from commands" do
    commands = fn
      "sh", ["-c", "command -v vmsan"], _opts ->
        {"/usr/bin/vmsan\n", 0}

      "sh", ["-c", "command -v sprite"], _opts ->
        {"/usr/local/bin/sprite\n", 0}

      "sh", ["-c", "command -v docker"], _opts ->
        {"/usr/bin/docker\n", 0}

      "/usr/bin/vmsan", ["--version"], _opts ->
        {"0.3.0\n", 0}

      "/usr/bin/vmsan", ["doctor", "--json"], _opts ->
        {Jason.encode!(vmsan_doctor_fixture()), 0}

      "/usr/local/bin/sprite", ["--help"], _opts ->
        {"sprite help text", 0}

      "/usr/bin/docker", ["info", "--format", "{{json .Runtimes}}"], _opts ->
        {"{}", 0}

      "uname", ["-a"], _opts ->
        {"Linux test 6.0 x86_64", 0}

      "systemd-detect-virt", [], _opts ->
        {"none\n", 0}

      "kvm-ok", [], _opts ->
        {"INFO: /dev/kvm exists\nKVM acceleration can be used\n", 0}

      _command, _args, _opts ->
        {"", 1}
    end

    env = fn
      "SPRITES_TOKEN" -> "secret-token"
      _name -> nil
    end

    probe = HostProbe.collect(commands: commands, env: env)

    assert probe.vmsan.installed?
    refute probe.vmsan.available?
    assert probe.vmsan.doctor.summary.failed == 8
    assert probe.sprites.installed?
    assert probe.sprites.auth_configured?
    assert probe.sprites.token_env == %{name: "SPRITES_TOKEN", present?: true, value: :redacted}
    refute inspect(probe) =~ "secret-token"
  end

  defp vmsan_doctor_fixture do
    %{
      "path" => "doctor",
      "checks" => [
        %{"category" => "System", "name" => "KVM", "status" => "pass", "detail" => "/dev/kvm"},
        %{
          "category" => "System",
          "name" => "TUN device",
          "status" => "pass",
          "detail" => "/dev/net/tun"
        },
        %{
          "category" => "System",
          "name" => "Disk space",
          "status" => "fail",
          "detail" => "Could not check disk space"
        },
        %{
          "category" => "System",
          "name" => "Default interface",
          "status" => "pass",
          "detail" => "eno1"
        },
        %{
          "category" => "System",
          "name" => "nftables kernel",
          "status" => "fail",
          "detail" => "nftables kernel support not available"
        },
        %{
          "category" => "System",
          "name" => "Host firewall",
          "status" => "pass",
          "detail" => "No conflicts"
        },
        %{
          "category" => "System",
          "name" => "Jailer filesystem",
          "status" => "pass",
          "detail" => "/"
        },
        %{
          "category" => "Binaries",
          "name" => "Firecracker",
          "status" => "fail",
          "detail" => "Not found"
        },
        %{
          "category" => "Binaries",
          "name" => "Jailer",
          "status" => "fail",
          "detail" => "Not found"
        },
        %{
          "category" => "Binaries",
          "name" => "Agent",
          "status" => "fail",
          "detail" => "Not found"
        },
        %{
          "category" => "Binaries",
          "name" => "vmsan-nftables",
          "status" => "fail",
          "detail" => "Not found"
        },
        %{
          "category" => "Images",
          "name" => "Kernel",
          "status" => "fail",
          "detail" => "Not found"
        },
        %{
          "category" => "Images",
          "name" => "Rootfs (base)",
          "status" => "fail",
          "detail" => "Not found"
        }
      ],
      "summary" => %{"passed" => 5, "failed" => 8, "total" => 13}
    }
  end

  defp vmsan_healthy_doctor_fixture do
    checks =
      vmsan_doctor_fixture()
      |> Map.fetch!("checks")
      |> Enum.map(&Map.put(&1, "status", "pass"))

    %{
      "path" => "doctor",
      "checks" => checks,
      "summary" => %{"passed" => length(checks), "failed" => 0, "total" => length(checks)}
    }
  end

  defp tmp_litter_box_dirs do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "litter_box_"))
    |> Enum.sort()
  end

  defp docker_image_available? do
    case System.find_executable("docker") do
      nil ->
        false

      docker ->
        case System.cmd(docker, ["image", "inspect", "runic-ai/sandbox:elixir-python-node"],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> true
          _other -> false
        end
    end
  rescue
    _exception -> false
  end

  defp docker_container_exists?(nil), do: false

  defp docker_container_exists?(container_name) do
    case System.find_executable("docker") do
      nil ->
        false

      docker ->
        case System.cmd(docker, ["container", "inspect", container_name], stderr_to_stdout: true) do
          {_output, 0} -> true
          _other -> false
        end
    end
  rescue
    _exception -> false
  end

  defp docker_network_exists?(nil), do: false

  defp docker_network_exists?(network_name) do
    case System.find_executable("docker") do
      nil ->
        false

      docker ->
        case System.cmd(docker, ["network", "inspect", network_name], stderr_to_stdout: true) do
          {_output, 0} -> true
          _other -> false
        end
    end
  rescue
    _exception -> false
  end

  defp host_http_get(url) do
    uri = URI.parse(url)
    port = uri.port || 80
    path = if uri.path in [nil, ""], do: "/", else: uri.path

    with {:ok, socket} <-
           :gen_tcp.connect(String.to_charlist(uri.host), port, [
             :binary,
             active: false,
             packet: :raw
           ]),
         :ok <-
           :gen_tcp.send(socket, [
             "GET ",
             path,
             " HTTP/1.1\r\nhost: ",
             uri.host,
             "\r\nconnection: close\r\n\r\n"
           ]),
         {:ok, response} <- recv_all(socket, "") do
      :gen_tcp.close(socket)
      parse_http_response(response)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_http_response(response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | _headers] = String.split(head, "\r\n")
    ["HTTP/" <> _version, status, _reason] = String.split(status_line, " ", parts: 3)
    {:ok, String.to_integer(status), body}
  rescue
    _exception -> {:error, :invalid_http_response}
  end

  defp start_mcp_http_server(body) do
    with {:ok, listen} <-
           :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true]) do
      {:ok, _pid} = Task.start(fn -> mcp_http_accept_loop(listen, body) end)
      {:ok, listen}
    end
  end

  defp mcp_http_accept_loop(listen, body) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        _ = :gen_tcp.recv(socket, 0, 5_000)

        response = [
          "HTTP/1.1 200 OK\r\n",
          "content-length: ",
          Integer.to_string(byte_size(body)),
          "\r\nconnection: close\r\n\r\n",
          body
        ]

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        mcp_http_accept_loop(listen, body)

      {:error, _reason} ->
        :ok
    end
  end

  defp docker_resource_names(prefix) do
    containers =
      case System.find_executable("docker") do
        nil ->
          []

        docker ->
          {output, _status} =
            System.cmd(
              docker,
              ["ps", "-a", "--filter", "name=#{prefix}", "--format", "{{.Names}}"],
              stderr_to_stdout: true
            )

          split_lines(output)
      end

    networks =
      case System.find_executable("docker") do
        nil ->
          []

        docker ->
          {output, _status} =
            System.cmd(
              docker,
              ["network", "ls", "--filter", "name=#{prefix}", "--format", "{{.Name}}"],
              stderr_to_stdout: true
            )

          split_lines(output)
      end

    containers ++ networks
  rescue
    _exception -> []
  end

  defp split_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp attach_event_types(%AttachHandle{} = handle), do: handle.events |> Enum.map(& &1.type)

  defp attach_stdout(%AttachHandle{} = handle), do: handle.events |> stdout_from_events()

  defp stdout_from_events(events) do
    events
    |> Enum.filter(&(&1.type == :stdout_chunk))
    |> Enum.map_join("", & &1.payload.chunk)
  end

  defp bridge_event(type, payload, id) do
    SessionEvent.new!(
      id: id,
      session_id: "session-bridge",
      type: type,
      payload: payload,
      metadata: %{source: :bridge_test}
    )
  end

  defp wait_until(fun, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until(fun, deadline, nil)
  end

  defp wait_until(fun, deadline, _last_value) do
    case fun.() do
      true ->
        true

      value ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(10)
          wait_until(fun, deadline, value)
        end
    end
  end
end
