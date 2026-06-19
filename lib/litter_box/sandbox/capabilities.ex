defmodule LitterBox.Capabilities do
  @moduledoc """
  Provider-neutral capability flags for a sandbox backend or session.
  """

  alias LitterBox.Error

  @attach_modes [:none, :terminal_adapter, :live_stream]
  @state_tiers [:one_shot_exec, :persistent_workspace, :persistent_process_host, :service_actor]
  @snapshot_modes [:filesystem, :microvm_snapshot, :provider_checkpoint]

  @attach_metadata_keys [
    :attach_mode,
    :streaming_live?,
    :terminal_result_adapter?,
    :stdin_supported?,
    :stdin_close_supported?,
    :stderr_separate?,
    :mcp_boundary_supported?,
    :restricted_egress_supported?,
    :pty_supported?,
    :state_tier,
    :process_host?,
    :workspace_persistent?,
    :live_process_stream?,
    :service_host?,
    :snapshot_modes
  ]

  @enforce_keys [
    :exec?,
    :files?,
    :inline_files?,
    :artifacts?,
    :session_files?,
    :checkpoints?,
    :services?,
    :proxy?,
    :leases?,
    :streaming?,
    :network_policy?,
    :persistent_identity?,
    :metadata
  ]
  defstruct exec?: false,
            files?: false,
            inline_files?: false,
            artifacts?: false,
            session_files?: false,
            checkpoints?: false,
            services?: false,
            proxy?: false,
            leases?: false,
            streaming?: false,
            network_policy?: false,
            persistent_identity?: false,
            metadata: %{}

  @type t :: %__MODULE__{
          exec?: boolean(),
          files?: boolean(),
          inline_files?: boolean(),
          artifacts?: boolean(),
          session_files?: boolean(),
          checkpoints?: boolean(),
          services?: boolean(),
          proxy?: boolean(),
          leases?: boolean(),
          streaming?: boolean(),
          network_policy?: boolean(),
          persistent_identity?: boolean(),
          metadata: map()
        }

  @type attach_mode :: :none | :terminal_adapter | :live_stream
  @type state_tier ::
          :one_shot_exec | :persistent_workspace | :persistent_process_host | :service_actor
  @type snapshot_mode :: :filesystem | :microvm_snapshot | :provider_checkpoint

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = capabilities), do: validate(capabilities)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    capabilities = %__MODULE__{
      exec?: get(input, :exec?, false),
      files?: get(input, :files?, false),
      inline_files?: get(input, :inline_files?, false),
      artifacts?: get(input, :artifacts?, false),
      session_files?: get(input, :session_files?, get(input, :files?, false)),
      checkpoints?: get(input, :checkpoints?, false),
      services?: get(input, :services?, false),
      proxy?: get(input, :proxy?, false),
      leases?: get(input, :leases?, false),
      streaming?: get(input, :streaming?, false),
      network_policy?: get(input, :network_policy?, false),
      persistent_identity?: get(input, :persistent_identity?, false),
      metadata: get(input, :metadata, %{})
    }

    validate(capabilities)
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, capabilities} -> capabilities
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec one_shot_exec(keyword() | map()) :: t()
  def one_shot_exec(input \\ []) do
    input = Map.new(input)

    %{
      exec?: true,
      files?: false,
      inline_files?: true,
      artifacts?: false,
      session_files?: false,
      checkpoints?: false,
      services?: false,
      proxy?: false,
      leases?: false,
      streaming?: get(input, :streaming?, false),
      network_policy?: get(input, :network_policy?, false),
      persistent_identity?: get(input, :persistent_identity?, false),
      metadata: get(input, :metadata, %{})
    }
    |> new!()
  end

  @spec attach_metadata(attach_mode(), keyword() | map()) :: map()
  def attach_metadata(mode, input \\ []) when mode in @attach_modes do
    input = input_map(input)

    defaults = %{
      attach_mode: mode,
      streaming_live?: get(input, :streaming_live?, mode == :live_stream),
      terminal_result_adapter?: get(input, :terminal_result_adapter?, mode == :terminal_adapter),
      stdin_supported?: get(input, :stdin_supported?, mode == :live_stream),
      stdin_close_supported?: get(input, :stdin_close_supported?, false),
      stderr_separate?: get(input, :stderr_separate?, false),
      mcp_boundary_supported?: get(input, :mcp_boundary_supported?, false),
      restricted_egress_supported?: get(input, :restricted_egress_supported?, false),
      pty_supported?: get(input, :pty_supported?, false),
      state_tier: state_tier_default(get(input, :state_tier, nil)),
      process_host?: get(input, :process_host?, false),
      workspace_persistent?: get(input, :workspace_persistent?, false),
      live_process_stream?: get(input, :live_process_stream?, mode == :live_stream),
      service_host?: get(input, :service_host?, false),
      snapshot_modes: get(input, :snapshot_modes, [])
    }

    input
    |> drop_attach_metadata_keys()
    |> Map.merge(defaults)
  end

  @spec attach_mode(t() | map()) :: attach_mode()
  def attach_mode(capabilities) when is_map(capabilities) do
    metadata = get(capabilities, :metadata, %{})

    case normalize_attach_mode(get(metadata, :attach_mode, nil)) do
      mode when mode in @attach_modes ->
        mode

      _other ->
        if get(capabilities, :streaming?, false), do: :terminal_adapter, else: :none
    end
  end

  @spec attach_supported?(t() | map()) :: boolean()
  def attach_supported?(capabilities), do: attach_mode(capabilities) != :none

  @spec streaming_live?(t() | map()) :: boolean()
  def streaming_live?(capabilities) do
    attach_mode(capabilities) == :live_stream or metadata_truthy?(capabilities, :streaming_live?)
  end

  @spec terminal_result_adapter?(t() | map()) :: boolean()
  def terminal_result_adapter?(capabilities) do
    attach_mode(capabilities) == :terminal_adapter or
      metadata_truthy?(capabilities, :terminal_result_adapter?)
  end

  @spec stdin_supported?(t() | map()) :: boolean()
  def stdin_supported?(capabilities) do
    metadata_truthy?(capabilities, :stdin_supported?) or attach_mode(capabilities) == :live_stream
  end

  @spec stdin_close_supported?(t() | map()) :: boolean()
  def stdin_close_supported?(capabilities),
    do: metadata_truthy?(capabilities, :stdin_close_supported?)

  @spec stderr_separate?(t() | map()) :: boolean()
  def stderr_separate?(capabilities), do: metadata_truthy?(capabilities, :stderr_separate?)

  @spec mcp_boundary_supported?(t() | map()) :: boolean()
  def mcp_boundary_supported?(capabilities),
    do: metadata_truthy?(capabilities, :mcp_boundary_supported?)

  @spec restricted_egress_supported?(t() | map()) :: boolean()
  def restricted_egress_supported?(capabilities),
    do: metadata_truthy?(capabilities, :restricted_egress_supported?)

  @spec pty_supported?(t() | map()) :: boolean()
  def pty_supported?(capabilities), do: metadata_truthy?(capabilities, :pty_supported?)

  @spec state_tier(t() | map()) :: state_tier()
  def state_tier(capabilities) when is_map(capabilities) do
    metadata = get(capabilities, :metadata, %{})

    case normalize_state_tier(get(metadata, :state_tier, nil)) do
      tier when tier in @state_tiers ->
        tier

      _other ->
        inferred_state_tier(capabilities)
    end
  end

  @spec process_host?(t() | map()) :: boolean()
  def process_host?(capabilities), do: metadata_truthy?(capabilities, :process_host?)

  @spec workspace_persistent?(t() | map()) :: boolean()
  def workspace_persistent?(capabilities) do
    metadata_truthy?(capabilities, :workspace_persistent?) or
      (get(capabilities, :persistent_identity?, false) and
         get(capabilities, :session_files?, false))
  end

  @spec live_process_stream?(t() | map()) :: boolean()
  def live_process_stream?(capabilities),
    do: metadata_truthy?(capabilities, :live_process_stream?)

  @spec service_host?(t() | map()) :: boolean()
  def service_host?(capabilities) do
    metadata_truthy?(capabilities, :service_host?) or
      get(capabilities, :services?, false) or get(capabilities, :proxy?, false)
  end

  @spec snapshot_modes(t() | map()) :: [snapshot_mode()]
  def snapshot_modes(capabilities) when is_map(capabilities) do
    capabilities
    |> get(:metadata, %{})
    |> get(:snapshot_modes, [])
    |> normalize_snapshot_modes()
  end

  @spec default_cwd(t() | map()) :: String.t() | nil
  def default_cwd(capabilities) do
    capabilities
    |> get(:metadata, %{})
    |> get(:default_cwd, nil)
    |> case do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = capabilities) do
    with :ok <- validate_boolean(capabilities.exec?, :exec?),
         :ok <- validate_boolean(capabilities.files?, :files?),
         :ok <- validate_boolean(capabilities.inline_files?, :inline_files?),
         :ok <- validate_boolean(capabilities.artifacts?, :artifacts?),
         :ok <- validate_boolean(capabilities.session_files?, :session_files?),
         :ok <- validate_boolean(capabilities.checkpoints?, :checkpoints?),
         :ok <- validate_boolean(capabilities.services?, :services?),
         :ok <- validate_boolean(capabilities.proxy?, :proxy?),
         :ok <- validate_boolean(capabilities.leases?, :leases?),
         :ok <- validate_boolean(capabilities.streaming?, :streaming?),
         :ok <- validate_boolean(capabilities.network_policy?, :network_policy?),
         :ok <- validate_boolean(capabilities.persistent_identity?, :persistent_identity?),
         :ok <- validate_map(capabilities.metadata, :metadata),
         :ok <- validate_optional_string(capabilities.metadata, :default_cwd),
         :ok <- validate_attach_metadata(capabilities.metadata),
         :ok <- validate_lifecycle_metadata(capabilities.metadata) do
      {:ok, capabilities}
    end
  end

  @spec to_map(t() | map()) :: map()
  def to_map(%__MODULE__{} = capabilities), do: Map.from_struct(capabilities)
  def to_map(capabilities) when is_map(capabilities), do: capabilities

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("sandbox capability #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox capability #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_string(metadata, field) do
    case get(metadata, field, nil) do
      nil ->
        :ok

      value when is_binary(value) and value != "" ->
        :ok

      value ->
        {:error,
         Error.validation("sandbox capability #{field} must be a non-empty string",
           source: __MODULE__,
           details: %{field: field, value: value}
         )}
    end
  end

  defp validate_attach_metadata(metadata) do
    case get(metadata, :attach_mode, nil) do
      nil ->
        :ok

      value ->
        case normalize_attach_mode(value) do
          mode when mode in @attach_modes ->
            :ok

          _other ->
            {:error,
             Error.validation("invalid sandbox attach capability mode",
               source: __MODULE__,
               details: %{attach_mode: value, valid_attach_modes: @attach_modes}
             )}
        end
    end
  end

  defp validate_lifecycle_metadata(metadata) do
    with :ok <- validate_state_tier(metadata),
         :ok <- validate_metadata_boolean(metadata, :process_host?),
         :ok <- validate_metadata_boolean(metadata, :workspace_persistent?),
         :ok <- validate_metadata_boolean(metadata, :live_process_stream?),
         :ok <- validate_metadata_boolean(metadata, :service_host?) do
      validate_snapshot_modes(metadata)
    end
  end

  defp validate_state_tier(metadata) do
    case get(metadata, :state_tier, nil) do
      nil ->
        :ok

      value ->
        case normalize_state_tier(value) do
          tier when tier in @state_tiers ->
            :ok

          _other ->
            {:error,
             Error.validation("invalid sandbox lifecycle state tier",
               source: __MODULE__,
               details: %{state_tier: value, valid_state_tiers: @state_tiers}
             )}
        end
    end
  end

  defp validate_metadata_boolean(metadata, field) do
    case get(metadata, field, nil) do
      nil ->
        :ok

      value when is_boolean(value) ->
        :ok

      value when value in ["true", "false"] ->
        :ok

      value ->
        {:error,
         Error.validation("sandbox capability #{field} metadata must be a boolean",
           source: __MODULE__,
           details: %{field: field, value: value}
         )}
    end
  end

  defp validate_snapshot_modes(metadata) do
    case get(metadata, :snapshot_modes, nil) do
      nil ->
        :ok

      value when is_list(value) ->
        invalid = Enum.reject(value, &(normalize_snapshot_mode(&1) in @snapshot_modes))

        if invalid == [] do
          :ok
        else
          {:error,
           Error.validation("invalid sandbox snapshot capability mode",
             source: __MODULE__,
             details: %{snapshot_modes: value, invalid_snapshot_modes: invalid}
           )}
        end

      value ->
        {:error,
         Error.validation("sandbox capability snapshot_modes metadata must be a list",
           source: __MODULE__,
           details: %{snapshot_modes: value}
         )}
    end
  end

  defp metadata_truthy?(capabilities, key) do
    capabilities
    |> get(:metadata, %{})
    |> get(key, false)
    |> truthy?()
  end

  defp truthy?(value) when value in [true, "true"], do: true
  defp truthy?(_value), do: false

  defp normalize_attach_mode(value) when value in @attach_modes, do: value

  defp normalize_attach_mode(value) when is_binary(value) do
    Enum.find(@attach_modes, &(Atom.to_string(&1) == value))
  end

  defp normalize_attach_mode(_value), do: nil

  defp state_tier_default(nil), do: :one_shot_exec
  defp state_tier_default(value), do: normalize_state_tier(value) || value

  defp inferred_state_tier(capabilities) do
    cond do
      service_host?(capabilities) ->
        :service_actor

      process_host?(capabilities) ->
        :persistent_process_host

      workspace_persistent?(capabilities) ->
        :persistent_workspace

      true ->
        :one_shot_exec
    end
  end

  defp normalize_state_tier(value) when value in @state_tiers, do: value

  defp normalize_state_tier(value) when is_binary(value) do
    Enum.find(@state_tiers, &(Atom.to_string(&1) == value))
  end

  defp normalize_state_tier(_value), do: nil

  defp normalize_snapshot_modes(value) when is_list(value) do
    value
    |> Enum.map(&normalize_snapshot_mode/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_snapshot_modes(_value), do: []

  defp normalize_snapshot_mode(value) when value in @snapshot_modes, do: value

  defp normalize_snapshot_mode(value) when is_binary(value) do
    Enum.find(@snapshot_modes, &(Atom.to_string(&1) == value))
  end

  defp normalize_snapshot_mode(_value), do: nil

  defp drop_attach_metadata_keys(input) do
    Enum.reduce(@attach_metadata_keys, input, fn key, acc ->
      acc
      |> Map.delete(key)
      |> Map.delete(Atom.to_string(key))
    end)
  end

  defp input_map(value) when is_map(value), do: value
  defp input_map(value) when is_list(value), do: Map.new(value)
  defp input_map(_value), do: %{}

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
