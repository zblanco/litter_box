defmodule LitterBox.Instance do
  @moduledoc """
  Runtime identity and backend metadata for a provisioned sandbox.
  """

  alias LitterBox.Error
  alias LitterBox.Policy
  alias LitterBox.Profile
  alias LitterBox.Workspace

  @valid_states [:new, :ready, :busy, :unavailable, :destroyed]

  @enforce_keys [
    :id,
    :name,
    :backend,
    :isolation_level,
    :state,
    :capabilities,
    :workspace,
    :metadata
  ]
  defstruct [
    :id,
    :name,
    :backend,
    :isolation_level,
    state: :new,
    capabilities: [],
    workspace: Workspace.new!(),
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: atom(),
          backend: Profile.backend(),
          isolation_level: Policy.isolation_level(),
          state: atom(),
          capabilities: [term()],
          workspace: Workspace.t(),
          metadata: map()
        }

  @spec from_profile(Profile.t(), keyword()) :: t()
  def from_profile(%Profile{} = profile, opts \\ []) do
    id = Keyword.get(opts, :id) || "#{profile.name}-#{System.unique_integer([:positive])}"

    %__MODULE__{
      id: to_string(id),
      name: profile.name,
      backend: profile.backend,
      isolation_level: profile.isolation_level,
      state: Keyword.get(opts, :state, :ready),
      capabilities: capabilities(profile),
      workspace: profile.workspace,
      metadata: Map.merge(profile.metadata, Keyword.get(opts, :metadata, %{}))
    }
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = instance) do
    with :ok <- validate_string(instance.id, :id),
         :ok <- validate_atom(instance.name, :name),
         :ok <- validate_atom(instance.backend, :backend),
         :ok <- validate_isolation(instance.isolation_level),
         :ok <- validate_state(instance.state),
         :ok <- validate_list(instance.capabilities, :capabilities),
         {:ok, workspace} <- Workspace.new(instance.workspace),
         :ok <- validate_map(instance.metadata, :metadata) do
      {:ok, %{instance | workspace: workspace}}
    end
  end

  defp capabilities(%Profile{} = profile) do
    Enum.map(profile.runtimes, &{:language, &1}) ++
      [
        {:backend, profile.backend},
        {:filesystem, profile.workspace.mode},
        {:network, profile.policy.network}
      ]
  end

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox instance #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_atom(value, _field) when is_atom(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("sandbox instance #{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_isolation(level) do
    if level in Policy.isolation_levels() do
      :ok
    else
      {:error,
       Error.validation("invalid sandbox instance isolation level",
         source: __MODULE__,
         details: %{isolation_level: level}
       )}
    end
  end

  defp validate_state(state) when state in @valid_states, do: :ok

  defp validate_state(state) do
    {:error,
     Error.validation("invalid sandbox instance state",
       source: __MODULE__,
       details: %{state: state, valid_states: @valid_states}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("sandbox instance #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox instance #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
