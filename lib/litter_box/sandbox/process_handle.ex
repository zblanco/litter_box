defmodule LitterBox.ProcessHandle do
  @moduledoc """
  Provider-neutral handle for a long-lived sandbox process.
  """

  alias LitterBox.Error

  @valid_statuses [:starting, :running, :exited, :failed, :killed, :closed, :error]

  @enforce_keys [:id, :session_id, :backend, :status, :events, :metadata]
  defstruct id: nil,
            session_id: nil,
            backend: nil,
            status: :running,
            command: [],
            events: [],
            metadata: %{}

  @type status :: :starting | :running | :exited | :failed | :killed | :closed | :error

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          backend: atom(),
          status: status(),
          command: [String.t()],
          events: term(),
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = handle), do: validate(handle)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    %__MODULE__{
      id: get(input, :id, nil),
      session_id: get(input, :session_id, nil),
      backend: normalize_atom(get(input, :backend, nil)),
      status: normalize_status(get(input, :status, :running)),
      command: get(input, :command, []),
      events: get(input, :events, []),
      metadata: get(input, :metadata, %{})
    }
    |> validate()
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, handle} -> handle
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec events(t()) :: Enumerable.t()
  def events(%__MODULE__{events: events}), do: events

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = handle) do
    with :ok <- validate_string(handle.id, :id),
         :ok <- validate_string(handle.session_id, :session_id),
         :ok <- validate_atom(handle.backend, :backend),
         :ok <- validate_status(handle.status),
         :ok <- validate_command(handle.command),
         :ok <- validate_map(handle.metadata, :metadata) do
      {:ok, handle}
    end
  end

  defp normalize_status(status) when status in @valid_statuses, do: status

  defp normalize_status(status) when is_binary(status) and status != "" do
    Enum.find(@valid_statuses, status, &(Atom.to_string(&1) == status))
  end

  defp normalize_status(status), do: status

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) and value != "" do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_atom(value), do: value

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox process handle #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_atom(value, _field) when is_atom(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("sandbox process handle #{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid sandbox process handle status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_command(command) when is_list(command), do: :ok

  defp validate_command(command) do
    {:error,
     Error.validation("sandbox process handle command must be a list",
       source: __MODULE__,
       details: %{command: command}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox process handle #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
