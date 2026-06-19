defmodule LitterBox.Workspace do
  @moduledoc """
  Describes how host workspace data is made available to a sandbox.
  """

  alias LitterBox.Error

  @valid_modes [:none, :copy_in, :bind_read_only, :bind, :stateful]

  @enforce_keys [:mode, :mount, :host_root, :persist?, :metadata]
  defstruct mode: :copy_in,
            mount: "/workspace",
            host_root: nil,
            persist?: false,
            metadata: %{}

  @type mode :: :none | :copy_in | :bind_read_only | :bind | :stateful

  @type t :: %__MODULE__{
          mode: mode(),
          mount: String.t(),
          host_root: Path.t() | nil,
          persist?: boolean(),
          metadata: map()
        }

  @spec new(keyword() | map() | t() | nil) :: {:ok, t()} | {:error, Error.t()}
  def new(nil), do: new([])
  def new(%__MODULE__{} = workspace), do: validate(workspace)

  def new(input) when is_map(input) do
    new(
      mode: get(input, :mode, :copy_in),
      mount: get(input, :mount, "/workspace"),
      host_root: get(input, :host_root, nil),
      persist?: get(input, :persist?, false),
      metadata: get(input, :metadata, %{})
    )
  end

  def new(opts) when is_list(opts) do
    mode = normalize_mode(Keyword.get(opts, :mode, :copy_in))
    mount = Keyword.get(opts, :mount, "/workspace")
    host_root = Keyword.get(opts, :host_root)
    persist? = Keyword.get(opts, :persist?, false)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_mode(mode),
         :ok <- validate_string(mount, :mount),
         :ok <- validate_optional_string(host_root, :host_root),
         :ok <- validate_boolean(persist?, :persist?),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         mode: mode,
         mount: mount,
         host_root: host_root,
         persist?: persist?,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map() | t() | nil) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, workspace} -> workspace
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = workspace) do
    new(
      mode: workspace.mode,
      mount: workspace.mount,
      host_root: workspace.host_root,
      persist?: workspace.persist?,
      metadata: workspace.metadata
    )
  end

  defp normalize_mode(mode) when mode in @valid_modes, do: mode
  defp normalize_mode("none"), do: :none
  defp normalize_mode("copy_in"), do: :copy_in
  defp normalize_mode("bind_read_only"), do: :bind_read_only
  defp normalize_mode("bind"), do: :bind
  defp normalize_mode("stateful"), do: :stateful
  defp normalize_mode(mode), do: mode

  defp validate_mode(mode) when mode in @valid_modes, do: :ok

  defp validate_mode(mode) do
    {:error,
     Error.validation("invalid sandbox workspace mode",
       source: __MODULE__,
       details: %{mode: mode, valid_modes: @valid_modes}
     )}
  end

  defp validate_optional_string(nil, _field), do: :ok
  defp validate_optional_string(value, field), do: validate_string(value, field)

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox workspace #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("sandbox workspace #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox workspace #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
