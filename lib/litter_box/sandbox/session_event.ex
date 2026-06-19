defmodule LitterBox.SessionEvent do
  @moduledoc """
  Observable lifecycle event emitted by a sandbox session backend.
  """

  alias LitterBox.Error

  @valid_types [
    :opened,
    :closed,
    :exec_started,
    :stdout_chunk,
    :stderr_chunk,
    :stdin_ack,
    :exec_finished,
    :process_started,
    :process_signaled,
    :process_killed,
    :process_finished,
    :file_written,
    :file_read,
    :checkpoint_created,
    :restored,
    :service_started,
    :service_stopped,
    :proxy_opened,
    :proxy_closed,
    :lease_acquired,
    :lease_released,
    :diagnostic
  ]

  @enforce_keys [:id, :session_id, :type, :at, :payload, :metadata]
  defstruct id: nil, session_id: nil, type: nil, at: nil, payload: %{}, metadata: %{}

  @type type ::
          :opened
          | :closed
          | :exec_started
          | :stdout_chunk
          | :stderr_chunk
          | :stdin_ack
          | :exec_finished
          | :process_started
          | :process_signaled
          | :process_killed
          | :process_finished
          | :file_written
          | :file_read
          | :checkpoint_created
          | :restored
          | :service_started
          | :service_stopped
          | :proxy_opened
          | :proxy_closed
          | :lease_acquired
          | :lease_released
          | :diagnostic

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          type: type(),
          at: DateTime.t(),
          payload: map(),
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = event), do: validate(event)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    %__MODULE__{
      id: get(input, :id, nil),
      session_id: get(input, :session_id, nil),
      type: normalize_type(get(input, :type, nil)),
      at: get(input, :at, DateTime.utc_now()),
      payload: get(input, :payload, %{}),
      metadata: get(input, :metadata, %{})
    }
    |> validate()
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, event} -> event
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = event) do
    with :ok <- validate_string(event.id, :id),
         :ok <- validate_string(event.session_id, :session_id),
         :ok <- validate_type(event.type),
         :ok <- validate_datetime(event.at, :at),
         :ok <- validate_map(event.payload, :payload),
         :ok <- validate_map(event.metadata, :metadata) do
      {:ok, event}
    end
  end

  defp normalize_type(type) when type in @valid_types, do: type

  defp normalize_type(type) when is_binary(type) and type != "" do
    Enum.find(@valid_types, type, &(Atom.to_string(&1) == type))
  end

  defp normalize_type(type), do: type

  defp validate_type(type) when type in @valid_types, do: :ok

  defp validate_type(type) do
    {:error,
     Error.validation("invalid sandbox session event type",
       source: __MODULE__,
       details: %{type: type, valid_types: @valid_types}
     )}
  end

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox session event #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_datetime(%DateTime{}, _field), do: :ok

  defp validate_datetime(value, field) do
    {:error,
     Error.validation("sandbox session event #{field} must be a DateTime",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox session event #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
