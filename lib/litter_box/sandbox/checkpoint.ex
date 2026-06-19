defmodule LitterBox.Checkpoint do
  @moduledoc """
  Provider-neutral checkpoint identity for a sandbox session.
  """

  alias LitterBox.Error

  @valid_kinds [
    :filesystem,
    :microvm_snapshot,
    :memory_snapshot,
    :provider_checkpoint,
    :suspended_session
  ]

  @enforce_keys [:id, :session_id, :backend, :ref, :created_at, :metadata]
  defstruct id: nil, session_id: nil, backend: nil, ref: nil, created_at: nil, metadata: %{}

  @type kind ::
          :filesystem
          | :microvm_snapshot
          | :memory_snapshot
          | :provider_checkpoint
          | :suspended_session

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          backend: atom(),
          ref: String.t(),
          created_at: DateTime.t() | nil,
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = checkpoint), do: validate(checkpoint)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    %__MODULE__{
      id: get(input, :id, nil),
      session_id: get(input, :session_id, nil),
      backend: get(input, :backend, nil),
      ref: get(input, :ref, nil),
      created_at: get(input, :created_at, nil),
      metadata: get(input, :metadata, %{})
    }
    |> validate()
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, checkpoint} -> checkpoint
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec kinds() :: [kind()]
  def kinds, do: @valid_kinds

  @spec kind(t() | map() | atom()) :: kind() | nil
  def kind(%__MODULE__{metadata: metadata}), do: kind(metadata)
  def kind(%{kind: kind}) when kind in @valid_kinds, do: kind
  def kind(%{"kind" => kind}) when is_binary(kind), do: kind_from_string(kind)
  def kind(kind) when kind in @valid_kinds, do: kind
  def kind(_other), do: nil

  @spec preserves(t() | map() | atom()) :: map()
  def preserves(%__MODULE__{metadata: %{preserves: preserves}}) when is_map(preserves),
    do: preserves

  def preserves(%__MODULE__{metadata: %{"preserves" => preserves}}) when is_map(preserves),
    do: Map.new(preserves, fn {key, value} -> {normalize_key(key), value} end)

  def preserves(input), do: preserves_for_kind(kind(input))

  @spec preserves?(t() | map() | atom(), atom()) :: boolean() | :provider_dependent | nil
  def preserves?(input, aspect) when is_atom(aspect) do
    input
    |> preserves()
    |> Map.get(aspect)
  end

  @spec support_matrix() :: map()
  def support_matrix do
    Map.new(@valid_kinds, &{&1, preserves_for_kind(&1)})
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = checkpoint) do
    with :ok <- validate_string(checkpoint.id, :id),
         :ok <- validate_string(checkpoint.session_id, :session_id),
         :ok <- validate_atom(checkpoint.backend, :backend),
         :ok <- validate_string(checkpoint.ref, :ref),
         :ok <- validate_optional_datetime(checkpoint.created_at, :created_at),
         :ok <- validate_map(checkpoint.metadata, :metadata) do
      {:ok, checkpoint}
    end
  end

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox checkpoint #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_atom(value, _field) when is_atom(value) and not is_nil(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("sandbox checkpoint #{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_datetime(nil, _field), do: :ok
  defp validate_optional_datetime(%DateTime{}, _field), do: :ok

  defp validate_optional_datetime(value, field) do
    {:error,
     Error.validation("sandbox checkpoint #{field} must be a DateTime",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox checkpoint #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp kind_from_string(value) do
    Enum.find(@valid_kinds, &(Atom.to_string(&1) == value))
  end

  defp preserves_for_kind(:filesystem) do
    %{
      filesystem: true,
      process_memory: false,
      running_processes: false,
      running_service_state: false,
      tcp_connections: false
    }
  end

  defp preserves_for_kind(:microvm_snapshot) do
    %{
      filesystem: true,
      process_memory: true,
      running_processes: true,
      running_service_state: true,
      tcp_connections: false
    }
  end

  defp preserves_for_kind(:memory_snapshot) do
    %{
      filesystem: :provider_dependent,
      process_memory: true,
      running_processes: true,
      running_service_state: true,
      tcp_connections: false
    }
  end

  defp preserves_for_kind(:provider_checkpoint) do
    %{
      filesystem: true,
      process_memory: :provider_dependent,
      running_processes: :provider_dependent,
      running_service_state: :provider_dependent,
      tcp_connections: false
    }
  end

  defp preserves_for_kind(:suspended_session) do
    %{
      filesystem: true,
      process_memory: true,
      running_processes: true,
      running_service_state: true,
      tcp_connections: false
    }
  end

  defp preserves_for_kind(_kind) do
    %{
      filesystem: :unknown,
      process_memory: :unknown,
      running_processes: :unknown,
      running_service_state: :unknown,
      tcp_connections: :unknown
    }
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    case key do
      "filesystem" -> :filesystem
      "process_memory" -> :process_memory
      "running_processes" -> :running_processes
      "running_service_state" -> :running_service_state
      "tcp_connections" -> :tcp_connections
      _other -> key
    end
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
