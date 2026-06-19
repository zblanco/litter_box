defmodule LitterBox.BackendHealth do
  @moduledoc """
  Provider-neutral health summary for sandbox backends and host probes.
  """

  alias LitterBox.Error

  @enforce_keys [
    :name,
    :backend,
    :status,
    :available?,
    :host_available?,
    :configured?,
    :exec_ready?,
    :isolation_level,
    :transport_model,
    :state_model,
    :capabilities,
    :diagnostics,
    :missing_requirements,
    :next_action,
    :metadata
  ]
  defstruct [
    :name,
    :backend,
    :status,
    :available?,
    :host_available?,
    :configured?,
    :exec_ready?,
    :isolation_level,
    :transport_model,
    :state_model,
    :capabilities,
    :diagnostics,
    :missing_requirements,
    :next_action,
    metadata: %{}
  ]

  @type status :: :available | :unavailable | :degraded | :unknown

  @type t :: %__MODULE__{
          name: atom(),
          backend: atom(),
          status: status(),
          available?: boolean(),
          host_available?: boolean(),
          configured?: boolean(),
          exec_ready?: boolean(),
          isolation_level: atom(),
          transport_model: atom(),
          state_model: atom(),
          capabilities: map(),
          diagnostics: [map()],
          missing_requirements: [map()],
          next_action: String.t() | nil,
          metadata: map()
        }

  @spec from_backend(atom(), atom(), map()) :: {:ok, t()} | {:error, Error.t()}
  def from_backend(name, backend, health)
      when is_atom(name) and is_atom(backend) and is_map(health) do
    available? = truthy?(Map.get(health, :available?, Map.get(health, "available?", false)))

    host_available? =
      truthy?(Map.get(health, :host_available?, Map.get(health, "host_available?", available?)))

    configured? =
      truthy?(Map.get(health, :configured?, Map.get(health, "configured?", available?)))

    exec_ready? =
      truthy?(Map.get(health, :exec_ready?, Map.get(health, "exec_ready?", available?)))

    diagnostics = list(Map.get(health, :diagnostics, Map.get(health, "diagnostics", [])))
    missing_requirements = missing_requirements(backend, health, diagnostics)

    new(
      name: name,
      backend: backend,
      status: status(exec_ready?, missing_requirements),
      available?: available?,
      host_available?: host_available?,
      configured?: configured?,
      exec_ready?: exec_ready?,
      isolation_level:
        Map.get(health, :isolation_level, Map.get(health, "isolation_level", :unknown)),
      transport_model: Map.get(health, :transport_model, transport_model(backend)),
      state_model: Map.get(health, :state_model, state_model(backend, health)),
      capabilities: Map.get(health, :capabilities, capabilities(backend, health)),
      diagnostics: diagnostics,
      missing_requirements: missing_requirements,
      next_action: next_action(backend, available?, missing_requirements),
      metadata: metadata(health)
    )
  end

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    health = struct(__MODULE__, input)

    with :ok <- validate_atom(health.name, :name),
         :ok <- validate_atom(health.backend, :backend),
         :ok <- validate_status(health.status),
         :ok <- validate_boolean(health.available?, :available?),
         :ok <- validate_boolean(health.host_available?, :host_available?),
         :ok <- validate_boolean(health.configured?, :configured?),
         :ok <- validate_boolean(health.exec_ready?, :exec_ready?),
         :ok <- validate_atom(health.isolation_level, :isolation_level),
         :ok <- validate_atom(health.transport_model, :transport_model),
         :ok <- validate_atom(health.state_model, :state_model),
         :ok <- validate_map(health.capabilities, :capabilities),
         :ok <- validate_list(health.diagnostics, :diagnostics),
         :ok <- validate_list(health.missing_requirements, :missing_requirements),
         :ok <- validate_optional_string(health.next_action, :next_action),
         :ok <- validate_map(health.metadata, :metadata) do
      {:ok, health}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, health} -> health
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp status(true, []), do: :available
  defp status(true, _missing), do: :degraded
  defp status(false, _missing), do: :unavailable

  defp capabilities(:just_bash, _health),
    do: %{
      exec?: true,
      files?: false,
      inline_files?: true,
      artifacts?: false,
      session_files?: false,
      checkpoints?: false,
      services?: false,
      proxy?: false,
      streaming?: false
    }

  defp capabilities(:lua, _health),
    do: %{
      exec?: true,
      files?: false,
      inline_files?: true,
      artifacts?: false,
      session_files?: false,
      checkpoints?: false,
      services?: false,
      proxy?: false,
      streaming?: false
    }

  defp capabilities(backend, health) when backend in [:docker, :gvisor] do
    %{
      exec?: true,
      files?: false,
      inline_files?: true,
      artifacts?: true,
      session_files?: false,
      checkpoints?: false,
      services?: false,
      proxy?: false,
      streaming?: false,
      network_policy?: true,
      persistent_identity?: truthy?(Map.get(health, :stateful?, false))
    }
  end

  defp capabilities(:vmsan, _health) do
    %{
      exec?: true,
      files?: false,
      inline_files?: false,
      artifacts?: false,
      session_files?: true,
      checkpoints?: true,
      services?: false,
      proxy?: false,
      streaming?: false,
      network_policy?: true,
      persistent_identity?: true
    }
  end

  defp capabilities(:remote, _health) do
    %{
      exec?: true,
      files?: false,
      inline_files?: false,
      artifacts?: false,
      session_files?: false,
      checkpoints?: false,
      services?: false,
      proxy?: false,
      streaming?: false,
      network_policy?: true,
      persistent_identity?: true
    }
  end

  defp capabilities(:sprites, _health) do
    %{
      exec?: true,
      files?: false,
      inline_files?: true,
      artifacts?: false,
      session_files?: true,
      checkpoints?: true,
      services?: true,
      proxy?: true,
      streaming?: false,
      network_policy?: true,
      persistent_identity?: true
    }
  end

  defp capabilities(_backend, _health), do: %{exec?: false}

  defp transport_model(:just_bash), do: :in_process
  defp transport_model(:lua), do: :in_process
  defp transport_model(:docker), do: :docker_cli
  defp transport_model(:gvisor), do: :docker_cli
  defp transport_model(:vmsan), do: :local_microvm
  defp transport_model(:sprites), do: :remote_microvm
  defp transport_model(:remote), do: :provider_cli
  defp transport_model(_backend), do: :unknown

  defp state_model(:just_bash, _health), do: :one_shot
  defp state_model(:lua, _health), do: :one_shot

  defp state_model(backend, health) when backend in [:docker, :gvisor] do
    if truthy?(Map.get(health, :stateful?, false)), do: :persistent_workspace, else: :one_shot
  end

  defp state_model(:remote, _health), do: :persistent_workspace
  defp state_model(:sprites, _health), do: :service_actor
  defp state_model(:vmsan, _health), do: :checkpointable
  defp state_model(_backend, _health), do: :unknown

  defp missing_requirements(backend, health, diagnostics) do
    case Map.get(health, :missing_requirements, Map.get(health, "missing_requirements")) do
      requirements when is_list(requirements) ->
        requirements

      _other ->
        []
        |> maybe_missing(
          not truthy?(Map.get(health, :docker_available?, true)),
          :docker,
          "Docker CLI is unavailable"
        )
        |> maybe_missing(
          backend == :gvisor and
            not truthy?(Map.get(health, :docker_runsc_runtime_available?, false)),
          :runsc,
          "Docker runsc runtime is unavailable"
        )
        |> maybe_missing(
          backend == :remote and not truthy?(Map.get(health, :configured?, true)),
          :provider_config,
          "Remote provider is not fully configured"
        )
        |> maybe_missing(
          backend == :remote and not truthy?(Map.get(health, :auth_configured?, true)) and
            truthy?(Map.get(health, :auth_required?, false)),
          :auth,
          "Remote provider credentials are not configured"
        )
        |> Kernel.++(diagnostic_missing_requirements(diagnostics))
        |> Enum.uniq_by(& &1.requirement)
    end
  end

  defp diagnostic_missing_requirements(diagnostics) do
    Enum.flat_map(diagnostics, fn diagnostic ->
      message = to_string(Map.get(diagnostic, :message, Map.get(diagnostic, "message", "")))

      cond do
        String.contains?(message, "Docker") ->
          [%{requirement: :docker, message: message}]

        String.contains?(message, "runsc") ->
          [%{requirement: :runsc, message: message}]

        String.contains?(message, "fly") or String.contains?(message, "Fly") ->
          [%{requirement: :fly_cli, message: message}]

        true ->
          []
      end
    end)
  end

  defp maybe_missing(requirements, true, requirement, message),
    do: [%{requirement: requirement, message: message} | requirements]

  defp maybe_missing(requirements, false, _requirement, _message), do: requirements

  defp next_action(_backend, true, []), do: nil

  defp next_action(:gvisor, _available?, missing) do
    if Enum.any?(missing, &(&1.requirement == :runsc)) do
      "Install/register the Docker runsc runtime, then rerun the doctor."
    else
      "Resolve missing gVisor backend requirements, then rerun the doctor."
    end
  end

  defp next_action(:remote, _available?, missing) do
    if Enum.any?(missing, &(&1.requirement in [:fly_cli, :provider_config])) do
      "Configure Fly CLI/app/machine_id credentials or choose a different remote provider."
    else
      "Resolve missing remote backend requirements, then rerun the doctor."
    end
  end

  defp next_action(backend, _available?, missing) do
    case missing do
      [] -> "Inspect #{backend} diagnostics and rerun the doctor."
      [first | _] -> "Resolve #{first.requirement}: #{first.message}"
    end
  end

  defp metadata(health) do
    health
    |> Map.drop([
      :diagnostics,
      "diagnostics",
      :capabilities,
      "capabilities",
      :available?,
      "available?",
      :isolation_level,
      "isolation_level"
    ])
  end

  defp truthy?(value), do: value in [true, "true", 1, "1", "yes", "on"]
  defp list(value) when is_list(value), do: value
  defp list(nil), do: []
  defp list(value), do: [value]

  defp validate_atom(value, _field) when is_atom(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("invalid backend health #{field}",
       source: __MODULE__,
       details: %{value: value}
     )}
  end

  defp validate_status(value) when value in [:available, :unavailable, :degraded, :unknown],
    do: :ok

  defp validate_status(value) do
    {:error,
     Error.validation("invalid backend health status",
       source: __MODULE__,
       details: %{status: value}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("invalid backend health #{field}",
       source: __MODULE__,
       details: %{value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("invalid backend health #{field}",
       source: __MODULE__,
       details: %{value: value}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("invalid backend health #{field}",
       source: __MODULE__,
       details: %{value: value}
     )}
  end

  defp validate_optional_string(nil, _field), do: :ok
  defp validate_optional_string(value, _field) when is_binary(value), do: :ok

  defp validate_optional_string(value, field) do
    {:error,
     Error.validation("invalid backend health #{field}",
       source: __MODULE__,
       details: %{value: value}
     )}
  end
end
