defmodule LitterBox.Profile do
  @moduledoc """
  Named sandbox configuration resolved from application or capability profile data.
  """

  alias LitterBox.Error
  alias LitterBox.Policy
  alias LitterBox.Workspace

  @valid_backends [
    :just_bash,
    :lua,
    :wasmtime,
    :docker,
    :podman,
    :gvisor,
    :vmsan,
    :sprites,
    :firecracker,
    :remote
  ]

  @enforce_keys [
    :name,
    :backend,
    :runtimes,
    :isolation_level,
    :policy,
    :workspace,
    :pool,
    :stateful?,
    :enabled?,
    :backend_options,
    :metadata
  ]
  defstruct name: :local_code,
            backend: :just_bash,
            runtimes: [:bash],
            isolation_level: :in_process_virtual,
            policy: Policy.new!(),
            workspace: Workspace.new!(),
            pool: %{
              warm: 0,
              max: 1,
              idle_ttl_ms: :infinity,
              checkout_timeout_ms: 0,
              reset_on_checkin?: false,
              checkpoint_on_checkout?: false,
              backend_affinity: :profile
            },
            stateful?: false,
            enabled?: true,
            backend_options: %{},
            metadata: %{}

  @type backend ::
          :just_bash
          | :lua
          | :wasmtime
          | :docker
          | :podman
          | :gvisor
          | :vmsan
          | :sprites
          | :firecracker
          | :remote

  @type t :: %__MODULE__{
          name: atom(),
          backend: backend(),
          runtimes: [atom()],
          isolation_level: Policy.isolation_level(),
          policy: Policy.t(),
          workspace: Workspace.t(),
          pool: map(),
          stateful?: boolean(),
          enabled?: boolean(),
          backend_options: map(),
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = profile), do: validate(profile)

  def new(input) when is_map(input) do
    backend = get(input, :backend, :just_bash)

    new(
      name: get(input, :name, :local_code),
      backend: backend,
      runtimes: get(input, :runtimes, default_runtimes(normalize_backend(backend))),
      isolation_level: get(input, :isolation_level, nil),
      policy: get(input, :policy, %{}),
      network: get(input, :network, nil),
      egress_allowlist: get(input, :egress_allowlist, nil),
      deny_by_default?: get(input, :deny_by_default?, nil),
      mcp_boundary: get(input, :mcp_boundary, nil),
      image: get(input, :image, nil),
      workspace: get(input, :workspace, %{}),
      pool: get(input, :pool, %{warm: 0, max: 1}),
      stateful?: get(input, :stateful?, false),
      enabled?: get(input, :enabled?, true),
      backend_options: get(input, :backend_options, %{}),
      metadata: get(input, :metadata, %{})
    )
  end

  def new(opts) when is_list(opts) do
    name = normalize_existing_atom(Keyword.get(opts, :name, :local_code))
    backend = normalize_backend(Keyword.get(opts, :backend, :just_bash))
    runtimes = Keyword.get(opts, :runtimes, default_runtimes(backend))

    isolation_level =
      (Keyword.get(opts, :isolation_level) || default_isolation(backend))
      |> normalize_isolation()

    policy_input = Keyword.get(opts, :policy, [])
    network = Keyword.get(opts, :network)
    image = Keyword.get(opts, :image)
    workspace_input = Keyword.get(opts, :workspace, [])
    pool = normalize_pool(Keyword.get(opts, :pool, %{warm: 0, max: 1}))
    stateful? = Keyword.get(opts, :stateful?, Keyword.get(opts, :persist?, false))
    enabled? = Keyword.get(opts, :enabled?, true)
    policy_runtimes = policy_runtimes(runtimes)

    backend_options =
      opts
      |> Keyword.get(:backend_options, %{})
      |> backend_options_map()
      |> maybe_put_image(image)

    metadata = Keyword.get(opts, :metadata, %{})

    policy_input =
      policy_input
      |> policy_input_map()
      |> Map.put_new(:allowed_runtimes, policy_runtimes)
      |> Map.put_new(:isolation_minimum, isolation_level)
      |> maybe_put_network(network)
      |> maybe_put_policy_field(:egress_allowlist, Keyword.get(opts, :egress_allowlist))
      |> maybe_put_policy_field(:deny_by_default?, Keyword.get(opts, :deny_by_default?))
      |> maybe_put_policy_field(:mcp_boundary, Keyword.get(opts, :mcp_boundary))

    with :ok <- validate_name(name),
         :ok <- validate_backend(backend),
         {:ok, runtimes} <- normalize_atom_list(runtimes, :runtimes),
         {:ok, policy} <- Policy.new(policy_input),
         {:ok, workspace} <- Workspace.new(workspace_input),
         :ok <- validate_isolation(isolation_level),
         {:ok, pool} <- pool,
         :ok <- validate_boolean(stateful?, :stateful?),
         :ok <- validate_boolean(enabled?, :enabled?),
         :ok <- validate_map(backend_options, :backend_options),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         name: name,
         backend: backend,
         runtimes: runtimes,
         policy: policy,
         workspace: workspace,
         pool: pool,
         stateful?: stateful?,
         enabled?: enabled?,
         backend_options: backend_options,
         metadata: metadata,
         isolation_level: isolation_level
       }}
    end
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, profile} -> profile
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = profile) do
    new(
      name: profile.name,
      backend: profile.backend,
      runtimes: profile.runtimes,
      isolation_level: profile.isolation_level,
      policy: profile.policy,
      workspace: profile.workspace,
      pool: profile.pool,
      stateful?: profile.stateful?,
      enabled?: profile.enabled?,
      backend_options: profile.backend_options,
      metadata: profile.metadata
    )
  end

  @spec from_named_config(atom(), keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_named_config(name, config) do
    config =
      config
      |> Map.new()
      |> Map.put(:name, name)

    new(config)
  end

  @spec default_isolation(atom()) :: Policy.isolation_level()
  def default_isolation(:just_bash), do: :in_process_virtual
  def default_isolation(:lua), do: :in_process
  def default_isolation(:wasmtime), do: :wasi
  def default_isolation(:docker), do: :container
  def default_isolation(:podman), do: :container
  def default_isolation(:gvisor), do: :gvisor
  def default_isolation(:vmsan), do: :microvm
  def default_isolation(:sprites), do: :remote_microvm
  def default_isolation(:firecracker), do: :microvm
  def default_isolation(:remote), do: :remote_microvm
  def default_isolation(_backend), do: :in_process

  defp default_runtimes(:lua), do: [:lua]
  defp default_runtimes(_backend), do: [:bash]

  defp validate_name(name) when is_atom(name), do: :ok

  defp validate_name(name) do
    {:error,
     Error.validation("sandbox profile name must be an atom",
       source: __MODULE__,
       details: %{name: name}
     )}
  end

  defp maybe_put_network(policy, nil), do: policy
  defp maybe_put_network(policy, network), do: Map.put_new(policy, :network, network)

  defp maybe_put_policy_field(policy, _field, nil), do: policy
  defp maybe_put_policy_field(policy, field, value), do: Map.put_new(policy, field, value)

  defp maybe_put_image(options, nil), do: options
  defp maybe_put_image(options, image), do: Map.put_new(options, :image, image)

  defp policy_input_map(%Policy{} = policy) do
    %{
      network: policy.network,
      timeout_ms: policy.timeout_ms,
      max_output_bytes: policy.max_output_bytes,
      allowed_runtimes: policy.allowed_runtimes,
      isolation_minimum: policy.isolation_minimum,
      persist_changes?: policy.persist_changes?,
      metadata: policy.metadata
    }
  end

  defp policy_input_map(value) when is_map(value), do: value
  defp policy_input_map(value) when is_list(value), do: Map.new(value)
  defp policy_input_map(_value), do: %{}

  defp backend_options_map(value) when is_map(value), do: value
  defp backend_options_map(value) when is_list(value), do: Map.new(value)
  defp backend_options_map(_value), do: %{}

  defp validate_backend(backend) when backend in @valid_backends, do: :ok

  defp validate_backend(backend) do
    {:error,
     Error.validation("invalid sandbox backend",
       source: __MODULE__,
       details: %{backend: backend, valid_backends: @valid_backends}
     )}
  end

  defp validate_isolation(level) do
    if level in Policy.isolation_levels() do
      :ok
    else
      {:error,
       Error.validation("invalid sandbox profile isolation level",
         source: __MODULE__,
         details: %{isolation_level: level, valid_isolation_levels: Policy.isolation_levels()}
       )}
    end
  end

  defp normalize_pool(pool) when is_list(pool), do: normalize_pool(Map.new(pool))

  defp normalize_pool(pool) when is_map(pool) do
    warm = get(pool, :warm, 0)
    max = get(pool, :max, 1)
    idle_ttl_ms = get(pool, :idle_ttl_ms, :infinity)
    checkout_timeout_ms = get(pool, :checkout_timeout_ms, 0)
    reset_on_checkin? = get(pool, :reset_on_checkin?, false)
    checkpoint_on_checkout? = get(pool, :checkpoint_on_checkout?, false)
    backend_affinity = normalize_existing_atom(get(pool, :backend_affinity, :profile))

    with :ok <- validate_pool_counts(warm, max, pool),
         :ok <- validate_pool_timeout(idle_ttl_ms, :idle_ttl_ms, pool),
         :ok <- validate_pool_timeout(checkout_timeout_ms, :checkout_timeout_ms, pool),
         :ok <- validate_boolean(reset_on_checkin?, :reset_on_checkin?),
         :ok <- validate_boolean(checkpoint_on_checkout?, :checkpoint_on_checkout?),
         :ok <- validate_backend_affinity(backend_affinity, pool) do
      {:ok,
       %{
         warm: warm,
         max: max,
         idle_ttl_ms: idle_ttl_ms,
         checkout_timeout_ms: checkout_timeout_ms,
         reset_on_checkin?: reset_on_checkin?,
         checkpoint_on_checkout?: checkpoint_on_checkout?,
         backend_affinity: backend_affinity
       }}
    end
  end

  defp normalize_pool(pool) do
    {:error,
     Error.validation("sandbox pool must be a map or keyword list",
       source: __MODULE__,
       details: %{pool: pool}
     )}
  end

  defp validate_pool_counts(warm, max, _pool)
       when is_integer(warm) and warm >= 0 and is_integer(max) and max > 0 and warm <= max,
       do: :ok

  defp validate_pool_counts(_warm, _max, pool) do
    {:error,
     Error.validation("sandbox pool must include non-negative warm and positive max",
       source: __MODULE__,
       details: %{pool: pool}
     )}
  end

  defp validate_pool_timeout(:infinity, _field, _pool), do: :ok

  defp validate_pool_timeout(value, _field, _pool) when is_integer(value) and value >= 0, do: :ok

  defp validate_pool_timeout(value, field, pool) do
    {:error,
     Error.validation("sandbox pool #{field} must be a non-negative integer or :infinity",
       source: __MODULE__,
       details: %{field: field, value: value, pool: pool}
     )}
  end

  defp validate_backend_affinity(value, _pool) when value in [:profile, :backend, :none], do: :ok

  defp validate_backend_affinity(value, pool) do
    {:error,
     Error.validation("sandbox pool backend_affinity is invalid",
       source: __MODULE__,
       details: %{backend_affinity: value, pool: pool, valid_values: [:profile, :backend, :none]}
     )}
  end

  defp normalize_backend(value) when value in @valid_backends, do: value

  defp normalize_backend(value) when is_binary(value) and value != "" do
    Enum.find(@valid_backends, value, &(Atom.to_string(&1) == value))
  end

  defp normalize_backend(value), do: value

  defp normalize_existing_atom(value) when is_atom(value), do: value

  defp normalize_existing_atom(value) when is_binary(value) and value != "" do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_existing_atom(value), do: value

  defp normalize_isolation(value) when is_atom(value) do
    if value in Policy.isolation_levels(), do: value, else: value
  end

  defp normalize_isolation(value) when is_binary(value) and value != "" do
    Enum.find(Policy.isolation_levels(), value, &(Atom.to_string(&1) == value))
  end

  defp normalize_isolation(value), do: value

  defp normalize_atom_list(values, field) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_existing_atom(value) do
        atom when is_atom(atom) -> {:cont, {:ok, [atom | acc]}}
        other -> {:halt, invalid_atom_list(field, other)}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_atom_list(value, field) when is_binary(value) and value != "" do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> normalize_atom_list(field)
  end

  defp normalize_atom_list(value, field), do: invalid_atom_list(field, value)

  defp policy_runtimes(runtimes) do
    case normalize_atom_list(runtimes, :runtimes) do
      {:ok, normalized} -> normalized
      {:error, _error} -> runtimes
    end
  end

  defp invalid_atom_list(field, value) do
    {:error,
     Error.validation("sandbox #{field} must be a list of atoms or strings",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("sandbox profile #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox profile #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
