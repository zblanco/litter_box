defmodule LitterBox.Lease do
  @moduledoc """
  Lease for exclusive or shared access to a sandbox session resource.
  """

  alias LitterBox.Error

  @valid_modes [:exclusive, :shared]
  @valid_statuses [:active, :released, :expired]

  @enforce_keys [:id, :session_id, :backend, :resource, :mode, :status, :expires_at, :metadata]
  defstruct id: nil,
            session_id: nil,
            backend: nil,
            resource: nil,
            mode: :exclusive,
            status: :active,
            expires_at: nil,
            metadata: %{}

  @type mode :: :exclusive | :shared
  @type status :: :active | :released | :expired

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          backend: atom(),
          resource: String.t(),
          mode: mode(),
          status: status(),
          expires_at: DateTime.t() | nil,
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = lease), do: validate(lease)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    %__MODULE__{
      id: get(input, :id, nil),
      session_id: get(input, :session_id, nil),
      backend: get(input, :backend, nil),
      resource: get(input, :resource, nil),
      mode: normalize_enum(get(input, :mode, :exclusive), @valid_modes),
      status: normalize_enum(get(input, :status, :active), @valid_statuses),
      expires_at: get(input, :expires_at, nil),
      metadata: get(input, :metadata, %{})
    }
    |> validate()
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, lease} -> lease
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = lease) do
    with :ok <- validate_string(lease.id, :id),
         :ok <- validate_string(lease.session_id, :session_id),
         :ok <- validate_atom(lease.backend, :backend),
         :ok <- validate_string(lease.resource, :resource),
         :ok <- validate_member(lease.mode, @valid_modes, :mode),
         :ok <- validate_member(lease.status, @valid_statuses, :status),
         :ok <- validate_optional_datetime(lease.expires_at, :expires_at),
         :ok <- validate_map(lease.metadata, :metadata) do
      {:ok, lease}
    end
  end

  defp normalize_enum(value, allowed) when is_atom(value) do
    if value in allowed, do: value, else: value
  end

  defp normalize_enum(value, allowed) when is_binary(value) and value != "" do
    Enum.find(allowed, value, &(Atom.to_string(&1) == value))
  end

  defp normalize_enum(value, _allowed), do: value

  defp validate_member(value, allowed, _field) do
    if value in allowed do
      :ok
    else
      {:error,
       Error.validation("invalid sandbox lease value",
         source: __MODULE__,
         details: %{value: value, allowed: allowed}
       )}
    end
  end

  defp validate_atom(value, _field) when is_atom(value) and not is_nil(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("sandbox lease #{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox lease #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_datetime(nil, _field), do: :ok
  defp validate_optional_datetime(%DateTime{}, _field), do: :ok

  defp validate_optional_datetime(value, field) do
    {:error,
     Error.validation("sandbox lease #{field} must be a DateTime",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox lease #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
