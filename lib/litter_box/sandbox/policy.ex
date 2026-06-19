defmodule LitterBox.Policy do
  @moduledoc """
  Execution policy for a sandbox profile or one execution request.
  """

  alias LitterBox.Error

  @valid_network [:disabled, :host, :restricted]
  @valid_egress_schemes ["http", "https", "tcp", "udp"]
  @valid_mcp_boundary_transports ["host_forward", "unix_socket", "egress_allowlist"]
  @valid_isolation_levels [
    :in_process,
    :in_process_virtual,
    :wasi,
    :namespace,
    :container,
    :gvisor,
    :microvm,
    :remote_microvm
  ]

  @enforce_keys [
    :network,
    :timeout_ms,
    :max_output_bytes,
    :allowed_runtimes,
    :isolation_minimum,
    :persist_changes?,
    :metadata
  ]
  defstruct network: :disabled,
            timeout_ms: 30_000,
            max_output_bytes: 65_536,
            allowed_runtimes: [],
            isolation_minimum: :in_process,
            persist_changes?: false,
            metadata: %{}

  @type network :: :disabled | :host | :restricted
  @type isolation_level ::
          :in_process
          | :in_process_virtual
          | :wasi
          | :namespace
          | :container
          | :gvisor
          | :microvm
          | :remote_microvm

  @type t :: %__MODULE__{
          network: network(),
          timeout_ms: pos_integer() | :infinity,
          max_output_bytes: pos_integer(),
          allowed_runtimes: [atom()],
          isolation_minimum: isolation_level(),
          persist_changes?: boolean(),
          metadata: map()
        }

  @spec isolation_levels() :: [isolation_level()]
  def isolation_levels, do: @valid_isolation_levels

  @spec egress_allowlist(t() | map()) :: [map()]
  def egress_allowlist(policy) when is_map(policy) do
    policy
    |> get(:metadata, %{})
    |> get(:egress_allowlist, [])
    |> List.wrap()
  end

  @spec restricted_egress_requested?(t() | map()) :: boolean()
  def restricted_egress_requested?(policy) when is_map(policy) do
    get(policy, :network, :disabled) == :restricted and egress_allowlist(policy) != []
  end

  @spec mcp_boundary(t() | map()) :: map() | nil
  def mcp_boundary(policy) when is_map(policy) do
    policy
    |> get(:metadata, %{})
    |> get(:mcp_boundary, nil)
  end

  @spec mcp_boundary_requested?(t() | map()) :: boolean()
  def mcp_boundary_requested?(policy) when is_map(policy), do: is_map(mcp_boundary(policy))

  @spec deny_by_default?(t() | map()) :: boolean()
  def deny_by_default?(policy) when is_map(policy) do
    policy
    |> get(:metadata, %{})
    |> get(:deny_by_default?, get(policy, :network, :disabled) == :restricted)
    |> truthy?()
  end

  @spec effective_network(t() | map()) :: map()
  def effective_network(policy) when is_map(policy) do
    %{
      mode: get(policy, :network, :disabled),
      deny_by_default?: deny_by_default?(policy),
      egress_allowlist: egress_allowlist(policy),
      restricted_egress?: restricted_egress_requested?(policy),
      mcp_boundary: mcp_boundary(policy)
    }
  end

  @spec new(keyword() | map() | t() | nil) :: {:ok, t()} | {:error, Error.t()}
  def new(nil), do: new([])
  def new(%__MODULE__{} = policy), do: validate(policy)

  def new(input) when is_map(input) do
    metadata =
      input
      |> get(:metadata, %{})
      |> put_metadata_input(:egress_allowlist, get(input, :egress_allowlist, :__missing__))
      |> put_metadata_input(:deny_by_default?, get(input, :deny_by_default?, :__missing__))
      |> put_metadata_input(:mcp_boundary, get(input, :mcp_boundary, :__missing__))

    new(
      network: get(input, :network, :disabled),
      timeout_ms: get(input, :timeout_ms, 30_000),
      max_output_bytes: get(input, :max_output_bytes, 65_536),
      allowed_runtimes: get(input, :allowed_runtimes, []),
      isolation_minimum: get(input, :isolation_minimum, :in_process),
      persist_changes?: get(input, :persist_changes?, false),
      metadata: metadata
    )
  end

  def new(opts) when is_list(opts) do
    network = normalize_network(Keyword.get(opts, :network, :disabled))
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, 65_536)
    allowed_runtimes = Keyword.get(opts, :allowed_runtimes, [])
    isolation_minimum = normalize_isolation(Keyword.get(opts, :isolation_minimum, :in_process))
    persist_changes? = Keyword.get(opts, :persist_changes?, false)

    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> put_metadata_input(:egress_allowlist, Keyword.get(opts, :egress_allowlist, :__missing__))
      |> put_metadata_input(:deny_by_default?, Keyword.get(opts, :deny_by_default?, :__missing__))
      |> put_metadata_input(:mcp_boundary, Keyword.get(opts, :mcp_boundary, :__missing__))

    with :ok <- validate_network(network),
         :ok <- validate_timeout(timeout_ms),
         :ok <- validate_positive_integer(max_output_bytes, :max_output_bytes),
         {:ok, allowed_runtimes} <- normalize_atom_list(allowed_runtimes, :allowed_runtimes),
         :ok <- validate_isolation(isolation_minimum),
         :ok <- validate_boolean(persist_changes?, :persist_changes?),
         {:ok, metadata} <- normalize_metadata(network, metadata) do
      {:ok,
       %__MODULE__{
         network: network,
         timeout_ms: timeout_ms,
         max_output_bytes: max_output_bytes,
         allowed_runtimes: allowed_runtimes,
         isolation_minimum: isolation_minimum,
         persist_changes?: persist_changes?,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map() | t() | nil) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    new(
      network: policy.network,
      timeout_ms: policy.timeout_ms,
      max_output_bytes: policy.max_output_bytes,
      allowed_runtimes: policy.allowed_runtimes,
      isolation_minimum: policy.isolation_minimum,
      persist_changes?: policy.persist_changes?,
      metadata: policy.metadata
    )
  end

  defp normalize_network(value) when value in @valid_network, do: value
  defp normalize_network("disabled"), do: :disabled
  defp normalize_network("host"), do: :host
  defp normalize_network("restricted"), do: :restricted
  defp normalize_network(%{enabled: false}), do: :disabled
  defp normalize_network(%{"enabled" => false}), do: :disabled
  defp normalize_network(%{enabled: true}), do: :host
  defp normalize_network(%{"enabled" => true}), do: :host
  defp normalize_network(value), do: value

  defp normalize_isolation(value) when value in @valid_isolation_levels, do: value

  defp normalize_isolation(value) when is_binary(value) and value != "" do
    Enum.find(@valid_isolation_levels, value, &(Atom.to_string(&1) == value))
  end

  defp normalize_isolation(value), do: value

  defp validate_network(network) when network in @valid_network, do: :ok

  defp validate_network(network) do
    {:error,
     Error.validation("invalid sandbox network policy",
       source: __MODULE__,
       details: %{network: network, valid_network: @valid_network}
     )}
  end

  defp validate_isolation(level) when level in @valid_isolation_levels, do: :ok

  defp validate_isolation(level) do
    {:error,
     Error.validation("invalid sandbox isolation level",
       source: __MODULE__,
       details: %{isolation_level: level, valid_isolation_levels: @valid_isolation_levels}
     )}
  end

  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(value), do: validate_positive_integer(value, :timeout_ms)

  defp validate_positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(value, field) do
    {:error,
     Error.validation("sandbox #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_atom_list(values, field) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_atom(value) do
        {:ok, atom} ->
          {:cont, {:ok, [atom | acc]}}

        {:error, error} ->
          {:halt, {:error, %{error | details: Map.put(error.details, :field, field)}}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_atom_list(value, field) do
    {:error,
     Error.validation("sandbox #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_atom(value) when is_atom(value), do: {:ok, value}

  defp normalize_atom(value) when is_binary(value) and value != "" do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError ->
      {:error,
       Error.validation("sandbox value must be a known atom string",
         source: __MODULE__,
         details: %{value: value}
       )}
  end

  defp normalize_atom(value) do
    {:error,
     Error.validation("sandbox value must be an atom or non-empty string",
       source: __MODULE__,
       details: %{value: value}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("sandbox #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_metadata(network, metadata) when is_map(metadata) do
    with {:ok, allowlist} <- normalize_egress_allowlist(get(metadata, :egress_allowlist, [])),
         :ok <- validate_allowlist_network(network, allowlist),
         {:ok, mcp_boundary} <- normalize_mcp_boundary(get(metadata, :mcp_boundary, nil)),
         :ok <- validate_mcp_boundary_network(network, allowlist, mcp_boundary),
         {:ok, deny_by_default?} <- normalize_deny_by_default(network, metadata) do
      metadata =
        metadata
        |> drop_metadata_keys([:egress_allowlist, :deny_by_default?, :mcp_boundary])
        |> Map.put(:egress_allowlist, allowlist)
        |> Map.put(:deny_by_default?, deny_by_default?)
        |> maybe_put_mcp_boundary(mcp_boundary)

      {:ok, metadata}
    end
  end

  defp normalize_metadata(_network, metadata), do: validate_map(metadata, :metadata)

  defp normalize_egress_allowlist(nil), do: {:ok, []}
  defp normalize_egress_allowlist([]), do: {:ok, []}

  defp normalize_egress_allowlist(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize_egress_entry(entry) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_egress_allowlist(value) do
    {:error,
     Error.validation("sandbox egress_allowlist must be a list",
       source: __MODULE__,
       details: %{egress_allowlist: value}
     )}
  end

  defp normalize_egress_entry(entry) when is_map(entry) do
    with {:ok, scheme} <- normalize_scheme(get(entry, :scheme, nil)),
         {:ok, host} <- normalize_host(get(entry, :host, nil)),
         {:ok, port} <- normalize_port(get(entry, :port, nil)),
         {:ok, purpose} <- normalize_purpose(get(entry, :purpose, nil)) do
      normalized = %{scheme: scheme, host: host, port: port}

      {:ok, maybe_put_purpose(normalized, purpose)}
    end
  end

  defp normalize_egress_entry(entry) do
    {:error,
     Error.validation("sandbox egress allow-list entries must be maps",
       source: __MODULE__,
       details: %{entry: entry}
     )}
  end

  defp normalize_scheme(scheme) when is_atom(scheme), do: normalize_scheme(Atom.to_string(scheme))

  defp normalize_scheme(scheme) when is_binary(scheme) and scheme != "" do
    scheme = String.downcase(scheme)

    if scheme in @valid_egress_schemes do
      {:ok, scheme}
    else
      {:error,
       Error.validation("invalid sandbox egress allow-list scheme",
         source: __MODULE__,
         details: %{scheme: scheme, valid_schemes: @valid_egress_schemes}
       )}
    end
  end

  defp normalize_scheme(scheme) do
    {:error,
     Error.validation("sandbox egress allow-list scheme must be a non-empty string",
       source: __MODULE__,
       details: %{scheme: scheme}
     )}
  end

  defp normalize_host(host) when is_binary(host) and host != "" do
    host = String.trim(host)

    if host != "" and not String.contains?(host, ["/", "\\"]) do
      {:ok, host}
    else
      invalid_host(host)
    end
  end

  defp normalize_host(host), do: invalid_host(host)

  defp invalid_host(host) do
    {:error,
     Error.validation("sandbox egress allow-list host must be a non-empty host name",
       source: __MODULE__,
       details: %{host: host}
     )}
  end

  defp normalize_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {port, ""} -> normalize_port(port)
      _other -> invalid_port(port)
    end
  end

  defp normalize_port(port) when is_integer(port) and port >= 1 and port <= 65_535,
    do: {:ok, port}

  defp normalize_port(port), do: invalid_port(port)

  defp invalid_port(port) do
    {:error,
     Error.validation("sandbox egress allow-list port must be between 1 and 65535",
       source: __MODULE__,
       details: %{port: port}
     )}
  end

  defp normalize_purpose(nil), do: {:ok, nil}
  defp normalize_purpose(purpose) when is_atom(purpose), do: {:ok, Atom.to_string(purpose)}
  defp normalize_purpose(purpose) when is_binary(purpose) and purpose != "", do: {:ok, purpose}

  defp normalize_purpose(purpose) do
    {:error,
     Error.validation("sandbox egress allow-list purpose must be an atom or non-empty string",
       source: __MODULE__,
       details: %{purpose: purpose}
     )}
  end

  defp maybe_put_purpose(entry, nil), do: entry
  defp maybe_put_purpose(entry, purpose), do: Map.put(entry, :purpose, purpose)

  defp validate_allowlist_network(:restricted, _allowlist), do: :ok
  defp validate_allowlist_network(_network, []), do: :ok

  defp validate_allowlist_network(network, allowlist) do
    {:error,
     Error.validation("sandbox egress_allowlist requires restricted networking",
       source: __MODULE__,
       details: %{network: network, egress_allowlist: allowlist}
     )}
  end

  defp normalize_mcp_boundary(nil), do: {:ok, nil}

  defp normalize_mcp_boundary(boundary) when is_map(boundary) do
    with {:ok, transport} <- normalize_mcp_transport(get(boundary, :transport, nil)) do
      normalize_mcp_boundary_transport(transport, boundary)
    end
  end

  defp normalize_mcp_boundary(boundary) do
    {:error,
     Error.validation("sandbox mcp_boundary must be a map",
       source: __MODULE__,
       details: %{mcp_boundary: boundary}
     )}
  end

  defp normalize_mcp_transport(transport) when is_atom(transport),
    do: normalize_mcp_transport(Atom.to_string(transport))

  defp normalize_mcp_transport(transport) when is_binary(transport) and transport != "" do
    transport = String.downcase(transport)

    if transport in @valid_mcp_boundary_transports do
      {:ok, transport}
    else
      {:error,
       Error.validation("invalid sandbox MCP boundary transport",
         source: __MODULE__,
         details: %{transport: transport, valid_transports: @valid_mcp_boundary_transports}
       )}
    end
  end

  defp normalize_mcp_transport(transport) do
    {:error,
     Error.validation("sandbox MCP boundary transport must be a non-empty string",
       source: __MODULE__,
       details: %{transport: transport}
     )}
  end

  defp normalize_mcp_boundary_transport("host_forward", boundary) do
    with {:ok, host} <- normalize_host(get(boundary, :host, nil)),
         {:ok, port} <- normalize_port(get(boundary, :port, nil)) do
      {:ok, %{transport: "host_forward", host: host, port: port}}
    end
  end

  defp normalize_mcp_boundary_transport("unix_socket", boundary) do
    case get(boundary, :path, nil) do
      path when is_binary(path) and path != "" ->
        {:ok, %{transport: "unix_socket", path: path}}

      path ->
        {:error,
         Error.validation("sandbox MCP unix_socket boundary requires a socket path",
           source: __MODULE__,
           details: %{path: path}
         )}
    end
  end

  defp normalize_mcp_boundary_transport("egress_allowlist", boundary) do
    purpose =
      boundary
      |> get(:purpose, "mcp")
      |> case do
        purpose when is_atom(purpose) -> Atom.to_string(purpose)
        purpose when is_binary(purpose) and purpose != "" -> purpose
        _other -> "mcp"
      end

    {:ok, %{transport: "egress_allowlist", purpose: purpose}}
  end

  defp validate_mcp_boundary_network(_network, _allowlist, nil), do: :ok
  defp validate_mcp_boundary_network(_network, _allowlist, %{transport: "host_forward"}), do: :ok
  defp validate_mcp_boundary_network(_network, _allowlist, %{transport: "unix_socket"}), do: :ok

  defp validate_mcp_boundary_network(:restricted, [_entry | _rest], %{
         transport: "egress_allowlist"
       }),
       do: :ok

  defp validate_mcp_boundary_network(
         network,
         allowlist,
         %{transport: "egress_allowlist"} = boundary
       ) do
    {:error,
     Error.validation("sandbox MCP egress_allowlist boundary requires restricted egress",
       source: __MODULE__,
       details: %{network: network, egress_allowlist: allowlist, mcp_boundary: boundary}
     )}
  end

  defp maybe_put_mcp_boundary(metadata, nil), do: metadata
  defp maybe_put_mcp_boundary(metadata, boundary), do: Map.put(metadata, :mcp_boundary, boundary)

  defp normalize_deny_by_default(:restricted, metadata) do
    metadata
    |> get(:deny_by_default?, true)
    |> normalize_boolean(:deny_by_default?)
  end

  defp normalize_deny_by_default(_network, metadata) do
    metadata
    |> get(:deny_by_default?, false)
    |> normalize_boolean(:deny_by_default?)
  end

  defp normalize_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean("true", _field), do: {:ok, true}
  defp normalize_boolean("false", _field), do: {:ok, false}

  defp normalize_boolean(value, field) do
    {:error,
     Error.validation("sandbox #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp put_metadata_input(metadata, _key, :__missing__), do: metadata

  defp put_metadata_input(metadata, key, value) when is_map(metadata) do
    Map.put_new(metadata, key, value)
  end

  defp put_metadata_input(metadata, _key, _value), do: metadata

  defp drop_metadata_keys(metadata, keys) do
    Enum.reduce(keys, metadata, fn key, acc ->
      acc
      |> Map.delete(key)
      |> Map.delete(Atom.to_string(key))
    end)
  end

  defp truthy?(value) when value in [true, "true"], do: true
  defp truthy?(_value), do: false

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
