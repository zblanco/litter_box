defmodule LitterBox.ProcessStatus do
  @moduledoc """
  Provider-neutral status snapshot for a sandbox process.
  """

  alias LitterBox.Error
  alias LitterBox.ProcessHandle

  @valid_statuses [:starting, :running, :exited, :failed, :killed, :closed, :error, :unknown]

  @enforce_keys [:id, :session_id, :backend, :status, :metadata]
  defstruct id: nil,
            session_id: nil,
            backend: nil,
            status: :unknown,
            pid: nil,
            exit_status: nil,
            started_at_ms: nil,
            finished_at_ms: nil,
            metadata: %{}

  @type status :: :starting | :running | :exited | :failed | :killed | :closed | :error | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          backend: atom(),
          status: status(),
          pid: integer() | nil,
          exit_status: integer() | nil,
          started_at_ms: integer() | nil,
          finished_at_ms: integer() | nil,
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = status), do: validate(status)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    %__MODULE__{
      id: get(input, :id, nil),
      session_id: get(input, :session_id, nil),
      backend: normalize_atom(get(input, :backend, nil)),
      status: normalize_status(get(input, :status, :unknown)),
      pid: get(input, :pid, nil),
      exit_status: get(input, :exit_status, nil),
      started_at_ms: get(input, :started_at_ms, nil),
      finished_at_ms: get(input, :finished_at_ms, nil),
      metadata: get(input, :metadata, %{})
    }
    |> validate()
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, status} -> status
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_handle(ProcessHandle.t(), keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_handle(%ProcessHandle{} = handle, input \\ []) do
    input = Map.new(input)

    new(%{
      id: get(input, :id, handle.id),
      session_id: get(input, :session_id, handle.session_id),
      backend: get(input, :backend, handle.backend),
      status: get(input, :status, handle.status),
      pid: get(input, :pid, nil),
      exit_status: get(input, :exit_status, nil),
      started_at_ms: get(input, :started_at_ms, nil),
      finished_at_ms: get(input, :finished_at_ms, nil),
      metadata: get(input, :metadata, handle.metadata)
    })
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = status) do
    with :ok <- validate_string(status.id, :id),
         :ok <- validate_string(status.session_id, :session_id),
         :ok <- validate_atom(status.backend, :backend),
         :ok <- validate_status(status.status),
         :ok <- validate_optional_integer(status.pid, :pid),
         :ok <- validate_optional_integer(status.exit_status, :exit_status),
         :ok <- validate_optional_integer(status.started_at_ms, :started_at_ms),
         :ok <- validate_optional_integer(status.finished_at_ms, :finished_at_ms),
         :ok <- validate_map(status.metadata, :metadata) do
      {:ok, status}
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
     Error.validation("sandbox process status #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_atom(value, _field) when is_atom(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("sandbox process status #{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid sandbox process status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_optional_integer(nil, _field), do: :ok
  defp validate_optional_integer(value, _field) when is_integer(value), do: :ok

  defp validate_optional_integer(value, field) do
    {:error,
     Error.validation("sandbox process status #{field} must be an integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox process status #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
