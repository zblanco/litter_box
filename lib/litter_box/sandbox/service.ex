defmodule LitterBox.Service do
  @moduledoc """
  Description of a long-running service inside a sandbox session.
  """

  alias LitterBox.Error

  @valid_statuses [:starting, :running, :stopped, :failed]

  @enforce_keys [:id, :session_id, :name, :status, :ports, :metadata]
  defstruct id: nil, session_id: nil, name: nil, status: :starting, ports: [], metadata: %{}

  @type status :: :starting | :running | :stopped | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          name: String.t(),
          status: status(),
          ports: [map()],
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = service), do: validate(service)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    %__MODULE__{
      id: get(input, :id, nil),
      session_id: get(input, :session_id, nil),
      name: get(input, :name, nil),
      status: normalize_status(get(input, :status, :starting)),
      ports: get(input, :ports, []),
      metadata: get(input, :metadata, %{})
    }
    |> validate()
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, service} -> service
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = service) do
    with :ok <- validate_string(service.id, :id),
         :ok <- validate_string(service.session_id, :session_id),
         :ok <- validate_string(service.name, :name),
         :ok <- validate_status(service.status),
         :ok <- validate_list(service.ports, :ports),
         :ok <- validate_map(service.metadata, :metadata) do
      {:ok, service}
    end
  end

  defp normalize_status(status) when status in @valid_statuses, do: status

  defp normalize_status(status) when is_binary(status) and status != "" do
    Enum.find(@valid_statuses, status, &(Atom.to_string(&1) == status))
  end

  defp normalize_status(status), do: status

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid sandbox service status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox service #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("sandbox service #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox service #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
