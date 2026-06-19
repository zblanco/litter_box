defmodule LitterBox.Proxy do
  @moduledoc """
  Host-visible proxy for a service running inside a sandbox session.
  """

  alias LitterBox.Error

  @valid_statuses [:opening, :open, :closed, :failed]

  @enforce_keys [:id, :session_id, :backend, :service_id, :status, :url, :local_port, :metadata]
  defstruct id: nil,
            session_id: nil,
            backend: nil,
            service_id: nil,
            status: :opening,
            url: nil,
            local_port: nil,
            metadata: %{}

  @type status :: :opening | :open | :closed | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          backend: atom(),
          service_id: String.t(),
          status: status(),
          url: String.t() | nil,
          local_port: pos_integer() | nil,
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = proxy), do: validate(proxy)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    %__MODULE__{
      id: get(input, :id, nil),
      session_id: get(input, :session_id, nil),
      backend: get(input, :backend, nil),
      service_id: get(input, :service_id, nil),
      status: normalize_status(get(input, :status, :opening)),
      url: get(input, :url, nil),
      local_port: get(input, :local_port, nil),
      metadata: get(input, :metadata, %{})
    }
    |> validate()
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, proxy} -> proxy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = proxy) do
    with :ok <- validate_string(proxy.id, :id),
         :ok <- validate_string(proxy.session_id, :session_id),
         :ok <- validate_atom(proxy.backend, :backend),
         :ok <- validate_string(proxy.service_id, :service_id),
         :ok <- validate_status(proxy.status),
         :ok <- validate_optional_string(proxy.url, :url),
         :ok <- validate_optional_positive_integer(proxy.local_port, :local_port),
         :ok <- validate_map(proxy.metadata, :metadata) do
      {:ok, proxy}
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
     Error.validation("invalid sandbox proxy status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox proxy #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_atom(value, _field) when is_atom(value) and not is_nil(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("sandbox proxy #{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_string(nil, _field), do: :ok
  defp validate_optional_string(value, field), do: validate_string(value, field)

  defp validate_optional_positive_integer(nil, _field), do: :ok

  defp validate_optional_positive_integer(value, _field)
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_optional_positive_integer(value, field) do
    {:error,
     Error.validation("sandbox proxy #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox proxy #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
