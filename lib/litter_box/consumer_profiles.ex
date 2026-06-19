defmodule LitterBox.ConsumerProfiles do
  @moduledoc """
  Example consumer profiles for systems that want to configure LitterBox
  without depending on RunicAI product modules.
  """

  @default_image "runic-ai/sandbox:elixir-python-node"
  @agent_cli_image "runic-ai/sandbox-agent-cli:latest"
  @agent_home "/opt/runic-ai/agents"
  @default_mcp_port 4000
  @default_model_proxy_port 4100

  @spec agent_cli_dev(keyword()) :: {atom(), keyword()}
  def agent_cli_dev(opts \\ []) do
    agent_cli_profile(:agent_cli_dev, :dev, opts,
      warm: Keyword.get(opts, :warm, 1),
      max: Keyword.get(opts, :max, 2),
      reset_on_checkin?: Keyword.get(opts, :reset_on_checkin?, false),
      checkpoint_on_checkout?: Keyword.get(opts, :checkpoint_on_checkout?, true)
    )
  end

  @spec agent_cli_execution(keyword()) :: {atom(), keyword()}
  def agent_cli_execution(opts \\ []) do
    agent_cli_profile(:agent_cli_execution, :execution, opts,
      warm: Keyword.get(opts, :warm, 1),
      max: Keyword.get(opts, :max, 4),
      reset_on_checkin?: Keyword.get(opts, :reset_on_checkin?, true),
      checkpoint_on_checkout?: Keyword.get(opts, :checkpoint_on_checkout?, false)
    )
  end

  @spec agent_cli_pair(keyword()) :: [{atom(), keyword()}]
  def agent_cli_pair(opts \\ []) do
    common_opts = Keyword.drop(opts, [:dev, :execution])

    [
      agent_cli_dev(Keyword.merge(common_opts, Keyword.get(opts, :dev, []))),
      agent_cli_execution(Keyword.merge(common_opts, Keyword.get(opts, :execution, [])))
    ]
  end

  @spec libbit_workspace(keyword()) :: {atom(), keyword()}
  def libbit_workspace(opts \\ []) do
    workspace_id = required_string!(opts, :workspace_id)
    tenant_id = Keyword.get(opts, :tenant_id)
    name = Keyword.get(opts, :name, :libbit_workspace)
    backend = Keyword.get(opts, :backend, :sprites)
    network = Keyword.get(opts, :network, :restricted)
    workspace_ref = safe_ref(workspace_id, tenant_id)

    {name,
     [
       backend: backend,
       runtimes: Keyword.get(opts, :runtimes, [:bash, :python, :node, :elixir]),
       network: network,
       stateful?: true,
       workspace: [
         mode: Keyword.get(opts, :workspace_mode, :copy_in),
         mount: Keyword.get(opts, :workspace_mount, "/workspace"),
         persist?: true,
         metadata: %{
           consumer: :libbit,
           workspace_id: workspace_id,
           workspace_ref: workspace_ref
         }
       ],
       pool: [
         warm: Keyword.get(opts, :warm, 1),
         max: Keyword.get(opts, :max, 4),
         idle_ttl_ms: Keyword.get(opts, :idle_ttl_ms, 300_000),
         checkout_timeout_ms: Keyword.get(opts, :checkout_timeout_ms, 5_000),
         reset_on_checkin?: Keyword.get(opts, :reset_on_checkin?, false),
         checkpoint_on_checkout?: Keyword.get(opts, :checkpoint_on_checkout?, true),
         backend_affinity: Keyword.get(opts, :backend_affinity, :profile)
       ],
       policy: [
         network: network,
         persist_changes?: true,
         metadata: %{
           checkpoint_on_risky_action?: Keyword.get(opts, :checkpoint_on_risky_action?, true)
         }
       ],
       backend_options: backend_options(backend, opts, workspace_ref),
       metadata: %{
         consumer: :libbit,
         workspace_id: workspace_id,
         tenant_id: tenant_id,
         workflow_run_id: Keyword.get(opts, :workflow_run_id),
         agent_id: Keyword.get(opts, :agent_id),
         actor_id: Keyword.get(opts, :actor_id),
         integration_status: :example_only
       }
     ]}
  end

  defp backend_options(:sprites, opts, workspace_ref) do
    %{
      sprite: Keyword.get(opts, :sprite, "libbit-#{workspace_ref}"),
      create_policy: Keyword.get(opts, :create_policy, :create_if_missing),
      organization: Keyword.get(opts, :organization),
      token_env: Keyword.get(opts, :token_env, "SPRITES_TOKEN")
    }
    |> reject_nil_values()
  end

  defp backend_options(:docker, opts, _workspace_ref) do
    %{
      image: Keyword.get(opts, :image, @default_image)
    }
  end

  defp backend_options(_backend, opts, _workspace_ref) do
    opts
    |> Keyword.get(:backend_options, %{})
    |> Map.new()
  end

  defp agent_cli_profile(default_name, role, opts, pool_defaults) do
    name = Keyword.get(opts, :name, default_name)
    backend = Keyword.get(opts, :backend, :docker)
    network = Keyword.get(opts, :network, :restricted)
    mcp_url = agent_endpoint_url(opts, :mcp_url, :mcp_port, @default_mcp_port)

    model_proxy_url =
      agent_endpoint_url(opts, :model_proxy_url, :model_proxy_port, @default_model_proxy_port)

    {name,
     [
       backend: backend,
       runtimes: Keyword.get(opts, :runtimes, [:bash, :python, :node, :elixir]),
       network: network,
       stateful?: true,
       workspace: [
         mode: Keyword.get(opts, :workspace_mode, :copy_in),
         mount: Keyword.get(opts, :workspace_mount, "/workspace"),
         persist?: Keyword.get(opts, :persist?, true),
         metadata: %{
           consumer: :agent_cli,
           role: role
         }
       ],
       pool: [
         warm: Keyword.fetch!(pool_defaults, :warm),
         max: Keyword.fetch!(pool_defaults, :max),
         idle_ttl_ms: Keyword.get(opts, :idle_ttl_ms, 300_000),
         checkout_timeout_ms: Keyword.get(opts, :checkout_timeout_ms, 5_000),
         reset_on_checkin?: Keyword.fetch!(pool_defaults, :reset_on_checkin?),
         checkpoint_on_checkout?: Keyword.fetch!(pool_defaults, :checkpoint_on_checkout?),
         backend_affinity: Keyword.get(opts, :backend_affinity, :profile)
       ],
       policy: [
         network: network,
         persist_changes?: true,
         egress_allowlist: [
           agent_endpoint_allowlist_entry(mcp_url, :mcp),
           agent_endpoint_allowlist_entry(model_proxy_url, :model)
         ],
         mcp_boundary: %{transport: :egress_allowlist, purpose: :mcp},
         metadata: %{
           credential_boundary: :host_proxy,
           internet_egress?: false
         }
       ],
       backend_options: agent_cli_backend_options(backend, opts, mcp_url, model_proxy_url),
       metadata: %{
         consumer: :agent_cli,
         role: role,
         agent_home: @agent_home,
         mcp_url_env: "RUNIC_MCP_URL",
         model_proxy_url_env: "RUNIC_MODEL_PROXY_URL",
         credential_boundary: :host_proxy,
         integration_status: :example_only
       }
     ]}
  end

  defp agent_cli_backend_options(backend, opts, mcp_url, model_proxy_url)
       when backend in [:docker, :gvisor] do
    base = %{
      image: Keyword.get(opts, :image, @agent_cli_image),
      environment: %{
        "RUNIC_MCP_URL" => mcp_url,
        "RUNIC_MODEL_PROXY_URL" => model_proxy_url
      }
    }

    merge_backend_options(base, Keyword.get(opts, :backend_options, %{}))
  end

  defp agent_cli_backend_options(_backend, opts, mcp_url, model_proxy_url) do
    base = %{
      environment: %{
        "RUNIC_MCP_URL" => mcp_url,
        "RUNIC_MODEL_PROXY_URL" => model_proxy_url
      }
    }

    merge_backend_options(base, Keyword.get(opts, :backend_options, %{}))
  end

  defp merge_backend_options(base, extra) do
    Map.merge(base, Map.new(extra || %{}), fn
      :environment, base_env, extra_env -> Map.merge(base_env, Map.new(extra_env || %{}))
      _key, _base_value, extra_value -> extra_value
    end)
  end

  defp agent_endpoint_url(opts, url_key, port_key, default_port) do
    Keyword.get(opts, url_key) ||
      "http://host.docker.internal:#{Keyword.get(opts, port_key, default_port)}"
  end

  defp agent_endpoint_allowlist_entry(url, purpose) do
    uri = URI.parse(url)

    %{
      scheme: uri.scheme || "http",
      host: uri.host || "host.docker.internal",
      port: uri.port || default_port(uri.scheme),
      purpose: purpose
    }
  end

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80

  defp required_string!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        value

      _other ->
        raise ArgumentError, "#{key} is required and must be a non-empty string"
    end
  end

  defp safe_ref(workspace_id, tenant_id) do
    slug =
      workspace_id
      |> slug()
      |> String.slice(0, 40)

    hash =
      [tenant_id, workspace_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(<<0>>)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "#{slug}-#{hash}"
  end

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "workspace"
      ref -> ref
    end
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
