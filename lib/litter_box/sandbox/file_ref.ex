defmodule LitterBox.FileRef do
  @moduledoc """
  Structured reference to a file visible through a sandbox session.
  """

  alias LitterBox.Error

  @valid_kinds [:file, :directory, :symlink, :unknown]

  @enforce_keys [:path, :kind, :bytes, :sha256, :metadata]
  defstruct path: nil, kind: :file, bytes: nil, sha256: nil, metadata: %{}

  @type kind :: :file | :directory | :symlink | :unknown

  @type t :: %__MODULE__{
          path: String.t(),
          kind: kind(),
          bytes: non_neg_integer() | nil,
          sha256: String.t() | nil,
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = ref), do: validate(ref)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    %__MODULE__{
      path: get(input, :path, nil),
      kind: normalize_kind(get(input, :kind, :file)),
      bytes: get(input, :bytes, nil),
      sha256: get(input, :sha256, nil),
      metadata: get(input, :metadata, %{})
    }
    |> validate()
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, ref} -> ref
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = ref) do
    with :ok <- validate_string(ref.path, :path),
         :ok <- validate_kind(ref.kind),
         :ok <- validate_optional_non_negative_integer(ref.bytes, :bytes),
         :ok <- validate_optional_string(ref.sha256, :sha256),
         :ok <- validate_map(ref.metadata, :metadata) do
      {:ok, ref}
    end
  end

  defp normalize_kind(kind) when kind in @valid_kinds, do: kind

  defp normalize_kind(kind) when is_binary(kind) and kind != "" do
    Enum.find(@valid_kinds, kind, &(Atom.to_string(&1) == kind))
  end

  defp normalize_kind(kind), do: kind

  defp validate_kind(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid sandbox file kind",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox file #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_string(nil, _field), do: :ok
  defp validate_optional_string(value, field), do: validate_string(value, field)

  defp validate_optional_non_negative_integer(nil, _field), do: :ok

  defp validate_optional_non_negative_integer(value, _field)
       when is_integer(value) and value >= 0,
       do: :ok

  defp validate_optional_non_negative_integer(value, field) do
    {:error,
     Error.validation("sandbox file #{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox file #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
