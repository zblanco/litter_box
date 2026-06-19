defmodule LitterBox.Session do
  @moduledoc """
  Runtime-neutral session handle for stateful or one-shot sandbox execution.
  """

  alias LitterBox.Capabilities
  alias LitterBox.Error
  alias LitterBox.Instance
  alias LitterBox.Policy

  @valid_states [:opening, :ready, :busy, :closed, :error]
  @valid_state_models [:one_shot, :persistent_workspace, :checkpointable, :service_actor]
  @valid_transport_models [
    :in_process,
    :docker_cli,
    :provider_cli,
    :local_microvm,
    :remote_microvm,
    :unknown
  ]

  @enforce_keys [
    :id,
    :sandbox,
    :backend,
    :state,
    :capabilities,
    :isolation_level,
    :state_model,
    :transport_model,
    :persistent_identity?,
    :workspace_ref,
    :policy,
    :authority,
    :metadata
  ]
  defstruct id: nil,
            sandbox: nil,
            backend: nil,
            state: :ready,
            capabilities: Capabilities.new!(),
            isolation_level: :in_process,
            state_model: :one_shot,
            transport_model: :unknown,
            persistent_identity?: false,
            workspace_ref: nil,
            policy: Policy.new!(),
            authority: nil,
            instance: nil,
            metadata: %{}

  @type state :: :opening | :ready | :busy | :closed | :error
  @type state_model :: :one_shot | :persistent_workspace | :checkpointable | :service_actor
  @type transport_model ::
          :in_process | :docker_cli | :provider_cli | :local_microvm | :remote_microvm | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          sandbox: atom(),
          backend: atom(),
          state: state(),
          capabilities: Capabilities.t(),
          isolation_level: Policy.isolation_level(),
          state_model: state_model(),
          transport_model: transport_model(),
          persistent_identity?: boolean(),
          workspace_ref: String.t() | nil,
          policy: Policy.t(),
          authority: map() | nil,
          instance: Instance.t() | nil,
          metadata: map()
        }

  @spec from_instance(Instance.t(), keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_instance(%Instance{} = instance, opts \\ []) do
    input = Map.new(opts)

    new(%{
      id: get(input, :id, instance.id),
      sandbox: get(input, :sandbox, instance.name),
      backend: get(input, :backend, instance.backend),
      state: get(input, :state, :ready),
      capabilities: get(input, :capabilities, capabilities_from_instance(instance)),
      isolation_level: get(input, :isolation_level, instance.isolation_level),
      state_model: get(input, :state_model, state_model_from_instance(instance)),
      transport_model: get(input, :transport_model, transport_model(instance.backend)),
      persistent_identity?: get(input, :persistent_identity?, persistent_identity?(instance)),
      workspace_ref: get(input, :workspace_ref, workspace_ref(instance)),
      policy: get(input, :policy, policy_from_instance(instance)),
      instance: get(input, :instance, instance),
      metadata: get(input, :metadata, %{})
    })
  end

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = session), do: validate(session)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    with {:ok, capabilities} <- Capabilities.new(get(input, :capabilities, %{})),
         {:ok, policy} <- Policy.new(get(input, :policy, %{})) do
      %__MODULE__{
        id: get(input, :id, nil),
        sandbox: get(input, :sandbox, nil),
        backend: get(input, :backend, nil),
        state: normalize_enum(get(input, :state, :ready), @valid_states),
        capabilities: capabilities,
        isolation_level: get(input, :isolation_level, :in_process),
        state_model: normalize_enum(get(input, :state_model, :one_shot), @valid_state_models),
        transport_model:
          normalize_enum(get(input, :transport_model, :unknown), @valid_transport_models),
        persistent_identity?: get(input, :persistent_identity?, false),
        workspace_ref: get(input, :workspace_ref, nil),
        policy: policy,
        authority: get(input, :authority, nil),
        instance: get(input, :instance, nil),
        metadata: get(input, :metadata, %{})
      }
      |> validate()
    end
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, session} -> session
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = session) do
    with :ok <- validate_string(session.id, :id),
         :ok <- validate_atom(session.sandbox, :sandbox),
         :ok <- validate_atom(session.backend, :backend),
         :ok <- validate_member(session.state, @valid_states, :state),
         {:ok, capabilities} <- Capabilities.new(session.capabilities),
         :ok <-
           validate_member(session.isolation_level, Policy.isolation_levels(), :isolation_level),
         :ok <- validate_member(session.state_model, @valid_state_models, :state_model),
         :ok <-
           validate_member(session.transport_model, @valid_transport_models, :transport_model),
         :ok <- validate_boolean(session.persistent_identity?, :persistent_identity?),
         :ok <- validate_optional_string(session.workspace_ref, :workspace_ref),
         {:ok, policy} <- Policy.new(session.policy),
         :ok <- validate_optional_map(session.authority, :authority),
         :ok <- validate_instance(session.instance),
         :ok <- validate_map(session.metadata, :metadata) do
      {:ok, %{session | capabilities: capabilities, policy: policy}}
    end
  end

  defp capabilities_from_instance(%Instance{} = instance) do
    Capabilities.one_shot_exec(
      network_policy?: Enum.any?(instance.capabilities, &match?({:network, _}, &1)),
      persistent_identity?: persistent_identity?(instance)
    )
  end

  defp state_model_from_instance(%Instance{} = instance) do
    if persistent_identity?(instance), do: :persistent_workspace, else: :one_shot
  end

  defp persistent_identity?(%Instance{} = instance) do
    metadata = instance.metadata
    Map.get(metadata, :stateful?, Map.get(metadata, "stateful?", false)) == true
  end

  defp workspace_ref(%Instance{} = instance) do
    case instance.workspace do
      %{persist?: true} -> "workspace://#{instance.id}"
      _other -> nil
    end
  end

  defp policy_from_instance(%Instance{} = instance) do
    network =
      instance.capabilities
      |> Enum.find_value(:disabled, fn
        {:network, network} -> network
        _other -> nil
      end)

    Policy.new!(network: network)
  end

  defp transport_model(:just_bash), do: :in_process
  defp transport_model(:lua), do: :in_process
  defp transport_model(:docker), do: :docker_cli
  defp transport_model(:gvisor), do: :docker_cli
  defp transport_model(:vmsan), do: :local_microvm
  defp transport_model(:remote), do: :provider_cli
  defp transport_model(_backend), do: :unknown

  defp normalize_enum(value, allowed) when is_atom(value) do
    if value in allowed, do: value, else: value
  end

  defp normalize_enum(value, allowed) when is_binary(value) and value != "" do
    Enum.find(allowed, value, &(Atom.to_string(&1) == value))
  end

  defp normalize_enum(value, _allowed), do: value

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox session #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_string(nil, _field), do: :ok
  defp validate_optional_string(value, field), do: validate_string(value, field)

  defp validate_atom(value, _field) when is_atom(value) and not is_nil(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("sandbox session #{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_member(value, allowed, field) do
    if value in allowed do
      :ok
    else
      {:error,
       Error.validation("invalid sandbox session #{field}",
         source: __MODULE__,
         details: %{field: field, value: value, allowed: allowed}
       )}
    end
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("sandbox session #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_instance(nil), do: :ok

  defp validate_instance(%Instance{} = instance) do
    case Instance.validate(instance) do
      {:ok, _instance} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp validate_instance(value) do
    {:error,
     Error.validation("sandbox session instance must be a LitterBox.Instance",
       source: __MODULE__,
       details: %{instance: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox session #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_map(nil, _field), do: :ok
  defp validate_optional_map(value, field), do: validate_map(value, field)

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
