defmodule LitterBox.ExecutionRequest do
  @moduledoc """
  Structured request for running code or a command inside a sandbox backend.
  """

  alias LitterBox.Error
  alias LitterBox.Policy

  @valid_modes [:script, :command]
  @valid_runtimes [:bash, :sh, :python, :node, :elixir, :lua]

  @enforce_keys [
    :sandbox,
    :runtime,
    :mode,
    :argv,
    :stdin,
    :cwd,
    :timeout_ms,
    :max_output_bytes,
    :network,
    :persist_changes?,
    :files,
    :metadata
  ]
  defstruct sandbox: :local_code,
            runtime: :bash,
            mode: :script,
            source: nil,
            argv: [],
            stdin: "",
            cwd: "/workspace",
            timeout_ms: 30_000,
            max_output_bytes: 65_536,
            network: :disabled,
            persist_changes?: false,
            files: %{},
            metadata: %{}

  @type mode :: :script | :command

  @type t :: %__MODULE__{
          sandbox: atom(),
          runtime: atom(),
          mode: mode(),
          source: String.t() | nil,
          argv: [String.t()],
          stdin: String.t(),
          cwd: String.t(),
          timeout_ms: pos_integer() | :infinity,
          max_output_bytes: pos_integer(),
          network: Policy.network(),
          persist_changes?: boolean(),
          files: map(),
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = request), do: validate(request)

  def new(input) when is_map(input) do
    new(
      sandbox: get(input, :sandbox, :local_code),
      runtime: get(input, :runtime, :bash),
      mode: get(input, :mode, :script),
      source: get(input, :source, get(input, :code, nil)),
      argv: get(input, :argv, []),
      stdin: get(input, :stdin, ""),
      cwd: get(input, :cwd, get(input, :sandbox_cwd, "/workspace")),
      timeout_ms: get(input, :timeout_ms, 30_000),
      max_output_bytes: get(input, :max_output_bytes, 65_536),
      network: get(input, :network, :disabled),
      persist_changes?: get(input, :persist_changes?, false),
      files: get(input, :files, %{}),
      metadata: get(input, :metadata, %{})
    )
  end

  def new(opts) when is_list(opts) do
    sandbox = normalize_existing_atom(Keyword.get(opts, :sandbox, :local_code))
    runtime = normalize_enum_atom(Keyword.get(opts, :runtime, :bash), @valid_runtimes)
    mode = normalize_enum_atom(Keyword.get(opts, :mode, :script), @valid_modes)
    source = Keyword.get(opts, :source, Keyword.get(opts, :code))
    argv = Keyword.get(opts, :argv, [])
    stdin = Keyword.get(opts, :stdin, "")
    cwd = Keyword.get(opts, :cwd, Keyword.get(opts, :sandbox_cwd, "/workspace"))
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, 65_536)
    network = normalize_network(Keyword.get(opts, :network, :disabled))
    persist_changes? = Keyword.get(opts, :persist_changes?, false)
    files = Keyword.get(opts, :files, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_atom(sandbox, :sandbox),
         :ok <- validate_atom(runtime, :runtime),
         :ok <- validate_mode(mode),
         :ok <- validate_source(mode, source),
         {:ok, argv} <- normalize_argv(argv),
         :ok <- validate_binary(stdin, :stdin),
         :ok <- validate_string(cwd, :cwd),
         :ok <- validate_timeout(timeout_ms),
         :ok <- validate_positive_integer(max_output_bytes, :max_output_bytes),
         :ok <- validate_network(network),
         :ok <- validate_boolean(persist_changes?, :persist_changes?),
         :ok <- validate_map(files, :files),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         sandbox: sandbox,
         runtime: runtime,
         mode: mode,
         source: source,
         argv: argv,
         stdin: stdin,
         cwd: cwd,
         timeout_ms: timeout_ms,
         max_output_bytes: max_output_bytes,
         network: network,
         persist_changes?: persist_changes?,
         files: files,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, request} -> request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = request) do
    new(
      sandbox: request.sandbox,
      runtime: request.runtime,
      mode: request.mode,
      source: request.source,
      argv: request.argv,
      stdin: request.stdin,
      cwd: request.cwd,
      timeout_ms: request.timeout_ms,
      max_output_bytes: request.max_output_bytes,
      network: request.network,
      persist_changes?: request.persist_changes?,
      files: request.files,
      metadata: request.metadata
    )
  end

  defp normalize_enum_atom(value, allowed) when is_atom(value) do
    if value in allowed, do: value, else: value
  end

  defp normalize_enum_atom(value, allowed) when is_binary(value) and value != "" do
    Enum.find(allowed, value, &(Atom.to_string(&1) == value))
  end

  defp normalize_enum_atom(value, _allowed), do: value

  defp normalize_existing_atom(value) when is_atom(value), do: value

  defp normalize_existing_atom(value) when is_binary(value) and value != "" do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_existing_atom(value), do: value

  defp normalize_network(:disabled), do: :disabled
  defp normalize_network(:host), do: :host
  defp normalize_network(:restricted), do: :restricted
  defp normalize_network("disabled"), do: :disabled
  defp normalize_network("host"), do: :host
  defp normalize_network("restricted"), do: :restricted
  defp normalize_network(%{enabled: false}), do: :disabled
  defp normalize_network(%{"enabled" => false}), do: :disabled
  defp normalize_network(%{enabled: true}), do: :host
  defp normalize_network(%{"enabled" => true}), do: :host
  defp normalize_network(value), do: value

  defp normalize_argv(argv) when is_list(argv) do
    if Enum.all?(argv, &is_binary/1) do
      {:ok, argv}
    else
      invalid_argv(argv)
    end
  end

  defp normalize_argv(argv), do: invalid_argv(argv)

  defp invalid_argv(argv) do
    {:error,
     Error.validation("sandbox argv must be a list of strings",
       source: __MODULE__,
       details: %{argv: argv}
     )}
  end

  defp validate_atom(value, _field) when is_atom(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("sandbox request #{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_mode(mode) when mode in @valid_modes, do: :ok

  defp validate_mode(mode) do
    {:error,
     Error.validation("invalid sandbox request mode",
       source: __MODULE__,
       details: %{mode: mode, valid_modes: @valid_modes}
     )}
  end

  defp validate_source(:script, source) when is_binary(source) and source != "", do: :ok

  defp validate_source(:script, source) do
    {:error,
     Error.validation("sandbox script request requires non-empty source",
       source: __MODULE__,
       details: %{source: source}
     )}
  end

  defp validate_source(:command, _source), do: :ok

  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(value), do: validate_positive_integer(value, :timeout_ms)

  defp validate_positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(value, field) do
    {:error,
     Error.validation("sandbox request #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_network(network) when network in [:disabled, :host, :restricted], do: :ok

  defp validate_network(network) do
    {:error,
     Error.validation("invalid sandbox request network policy",
       source: __MODULE__,
       details: %{network: network}
     )}
  end

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox request #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_binary(value, _field) when is_binary(value), do: :ok

  defp validate_binary(value, field) do
    {:error,
     Error.validation("sandbox request #{field} must be a binary",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("sandbox request #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox request #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
