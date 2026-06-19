defmodule LitterBox.ExecutionResult do
  @moduledoc """
  Structured result returned by every sandbox backend.
  """

  alias LitterBox.Error
  alias LitterBox.Policy

  @valid_statuses [:pass, :fail, :timeout, :blocked, :error]
  @valid_backends [
    :just_bash,
    :lua,
    :wasmtime,
    :docker,
    :podman,
    :gvisor,
    :vmsan,
    :firecracker,
    :remote
  ]

  @enforce_keys [
    :status,
    :stdout,
    :stderr,
    :duration_ms,
    :files_changed,
    :artifacts,
    :backend,
    :isolation_level,
    :diagnostics,
    :resource_usage,
    :metadata
  ]
  defstruct status: :pass,
            stdout: "",
            stderr: "",
            exit_status: nil,
            duration_ms: 0,
            files_changed: [],
            artifacts: [],
            backend: nil,
            isolation_level: nil,
            diagnostics: [],
            resource_usage: %{},
            metadata: %{}

  @type status :: :pass | :fail | :timeout | :blocked | :error

  @type t :: %__MODULE__{
          status: status(),
          stdout: binary(),
          stderr: binary(),
          exit_status: non_neg_integer() | nil,
          duration_ms: non_neg_integer(),
          files_changed: [map()],
          artifacts: [map()],
          backend: atom(),
          isolation_level: Policy.isolation_level(),
          diagnostics: [map()],
          resource_usage: map(),
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = result), do: validate(result)

  def new(input) when is_map(input) do
    new(
      status: get(input, :status, :pass),
      stdout: get(input, :stdout, ""),
      stderr: get(input, :stderr, ""),
      exit_status: get(input, :exit_status, nil),
      duration_ms: get(input, :duration_ms, 0),
      files_changed: get(input, :files_changed, []),
      artifacts: get(input, :artifacts, []),
      backend: get(input, :backend, nil),
      isolation_level: get(input, :isolation_level, nil),
      diagnostics: get(input, :diagnostics, []),
      resource_usage: get(input, :resource_usage, %{}),
      metadata: get(input, :metadata, %{})
    )
  end

  def new(opts) when is_list(opts) do
    status = normalize_enum_atom(Keyword.get(opts, :status, :pass), @valid_statuses)
    stdout = Keyword.get(opts, :stdout, "")
    stderr = Keyword.get(opts, :stderr, "")
    exit_status = Keyword.get(opts, :exit_status)
    duration_ms = Keyword.get(opts, :duration_ms, 0)
    files_changed = Keyword.get(opts, :files_changed, [])
    artifacts = Keyword.get(opts, :artifacts, [])
    backend = normalize_enum_atom(Keyword.get(opts, :backend), @valid_backends)

    isolation_level =
      normalize_enum_atom(Keyword.get(opts, :isolation_level), Policy.isolation_levels())

    diagnostics = Keyword.get(opts, :diagnostics, [])
    resource_usage = Keyword.get(opts, :resource_usage, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_status(status),
         :ok <- validate_binary(stdout, :stdout),
         :ok <- validate_binary(stderr, :stderr),
         :ok <- validate_optional_non_negative_integer(exit_status, :exit_status),
         :ok <- validate_non_negative_integer(duration_ms, :duration_ms),
         :ok <- validate_list(files_changed, :files_changed),
         :ok <- validate_list(artifacts, :artifacts),
         :ok <- validate_atom(backend, :backend),
         :ok <- validate_isolation(isolation_level),
         :ok <- validate_list(diagnostics, :diagnostics),
         :ok <- validate_map(resource_usage, :resource_usage),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         status: status,
         stdout: stdout,
         stderr: stderr,
         exit_status: exit_status,
         duration_ms: duration_ms,
         files_changed: files_changed,
         artifacts: artifacts,
         backend: backend,
         isolation_level: isolation_level,
         diagnostics: diagnostics,
         resource_usage: resource_usage,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = result) do
    new(
      status: result.status,
      stdout: result.stdout,
      stderr: result.stderr,
      exit_status: result.exit_status,
      duration_ms: result.duration_ms,
      files_changed: result.files_changed,
      artifacts: result.artifacts,
      backend: result.backend,
      isolation_level: result.isolation_level,
      diagnostics: result.diagnostics,
      resource_usage: result.resource_usage,
      metadata: result.metadata
    )
  end

  defp normalize_enum_atom(nil, _allowed), do: nil

  defp normalize_enum_atom(value, allowed) when is_atom(value) do
    if value in allowed, do: value, else: value
  end

  defp normalize_enum_atom(value, allowed) when is_binary(value) and value != "" do
    Enum.find(allowed, value, &(Atom.to_string(&1) == value))
  end

  defp normalize_enum_atom(value, _allowed), do: value

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid sandbox execution status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_binary(value, _field) when is_binary(value), do: :ok

  defp validate_binary(value, field) do
    {:error,
     Error.validation("sandbox execution #{field} must be a binary",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_non_negative_integer(nil, _field), do: :ok

  defp validate_optional_non_negative_integer(value, field),
    do: validate_non_negative_integer(value, field)

  defp validate_non_negative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_negative_integer(value, field) do
    {:error,
     Error.validation("sandbox execution #{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_atom(value, _field) when is_atom(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("sandbox execution #{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_isolation(level) do
    if level in Policy.isolation_levels() do
      :ok
    else
      {:error,
       Error.validation("sandbox execution result requires valid isolation_level metadata",
         source: __MODULE__,
         details: %{isolation_level: level, valid_isolation_levels: Policy.isolation_levels()}
       )}
    end
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("sandbox execution #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox execution #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
