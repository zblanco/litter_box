defmodule LitterBox.Reports do
  @moduledoc """
  Structured validation reports for sandbox backends.
  """

  alias LitterBox.BackendHealth
  alias LitterBox.HostProbe
  alias LitterBox.Profile

  @default_health_profiles [
    [name: :just_bash, backend: :just_bash, runtimes: [:bash], network: :disabled],
    [name: :lua, backend: :lua, runtimes: [:lua], network: :disabled],
    [name: :docker, backend: :docker, runtimes: [:bash], network: :disabled],
    [name: :gvisor, backend: :gvisor, runtimes: [:bash], network: :disabled],
    [name: :vmsan, backend: :vmsan, runtimes: [:bash], network: :disabled],
    [name: :sprites, backend: :sprites, runtimes: [:bash], network: :restricted],
    [
      name: :remote_fly,
      backend: :remote,
      runtimes: [:bash],
      network: :restricted,
      backend_options: [provider: :fly_machines]
    ]
  ]

  @security_rows [
    %{
      backend: :just_bash,
      isolation_level: :in_process_virtual,
      security_boundary?: false,
      boundary: "BEAM process plus JustBash virtual filesystem semantics",
      limitations: [
        "Not an OS security boundary",
        "Use for tests, demos, and trusted local convenience only"
      ],
      publish_as: :base_optional_dependency
    },
    %{
      backend: :lua,
      isolation_level: :in_process,
      security_boundary?: false,
      boundary: "BEAM process running Luerl through the optional lua package",
      limitations: [
        "Not an OS security boundary",
        "Best for small deterministic transform snippets"
      ],
      publish_as: :base_optional_dependency
    },
    %{
      backend: :docker,
      isolation_level: :container,
      security_boundary?: true,
      boundary: "Docker daemon container isolation with explicit argv construction",
      limitations: [
        "Trusts the local Docker daemon",
        "Not a microVM",
        "Host bind mounts and network policy must remain explicit"
      ],
      publish_as: :base_adapter
    },
    %{
      backend: :gvisor,
      isolation_level: :gvisor,
      security_boundary?: true,
      boundary: "Docker container executed with the runsc runtime",
      limitations: [
        "Requires Docker runsc runtime registration",
        "Still depends on the local container engine"
      ],
      publish_as: :base_adapter
    },
    %{
      backend: :vmsan,
      isolation_level: :microvm,
      security_boundary?: true,
      boundary: "Local Firecracker microVM managed through the vmsan CLI",
      limitations: [
        "Requires vmsan assets and host kernel support",
        "Create, snapshot, and remove may require explicit sudo configuration"
      ],
      publish_as: :base_adapter
    },
    %{
      backend: :remote,
      isolation_level: :remote_microvm,
      security_boundary?: true,
      boundary: "Provider-owned remote machine or microVM boundary",
      limitations: [
        "Availability, startup latency, and snapshot semantics depend on provider",
        "Credentials and remote lifecycle policy must be supplied by the host app"
      ],
      publish_as: :separate_adapter_candidate
    },
    %{
      backend: :sprites,
      isolation_level: :remote_microvm,
      security_boundary?: true,
      boundary: "Sprites hosted persistent Linux sandbox reached through the Sprites API",
      limitations: [
        "Requires SPRITES_TOKEN or configured token env",
        "WebSocket exec/proxy streaming is modeled as metadata in the base adapter"
      ],
      publish_as: :base_adapter
    },
    %{
      backend: :firecracker,
      isolation_level: :microvm,
      security_boundary?: true,
      boundary: "Reserved for a future direct Firecracker/KVM adapter",
      limitations: [
        "Not implemented in the base package",
        "Prefer vmsan or similar wrappers before owning jailer/rootfs/networking directly"
      ],
      publish_as: :future_adapter
    }
  ]

  @spec health_matrix([keyword() | map() | Profile.t()]) :: map()
  def health_matrix(profiles \\ @default_health_profiles) do
    %{
      generated_at: DateTime.utc_now(),
      host: host(),
      rows: Enum.map(profiles, &health_row/1),
      platform_notes: platform_notes()
    }
  end

  @spec doctor(keyword()) :: map()
  def doctor(opts \\ []) do
    %{
      generated_at: DateTime.utc_now(),
      host_probe: HostProbe.collect(opts),
      health_matrix: health_matrix(),
      security_posture: security_posture(),
      publication_strategy: publication_strategy()
    }
  end

  @spec security_posture() :: map()
  def security_posture do
    %{
      generated_at: DateTime.utc_now(),
      rows: @security_rows,
      publication_strategy: publication_strategy()
    }
  end

  @spec latency_report([keyword() | map() | Profile.t()]) :: map()
  def latency_report(profiles \\ latency_profiles()) do
    %{
      generated_at: DateTime.utc_now(),
      host: host(),
      rows: Enum.map(profiles, &latency_row/1)
    }
  end

  @spec publication_strategy() :: map()
  def publication_strategy do
    %{
      base_package: %{
        app: :litter_box,
        contains: [
          :contracts,
          :manager,
          :backend_behaviour,
          :just_bash_adapter,
          :lua_adapter,
          :docker_adapter,
          :gvisor_docker_adapter,
          :vmsan_adapter,
          :sprites_adapter,
          :remote_provider_adapter_contract
        ],
        required_dependencies: [:jason],
        optional_dependencies: [:just_bash, :lua]
      },
      split_later: [
        %{
          app: :litter_box_fly,
          when: "remote provider lifecycle grows beyond local health and fly machine exec",
          owns: [:fly_machines_api_client, :sprites_lifecycle, :credential_policy]
        },
        %{
          app: :litter_box_vmsan,
          when: "local microVM execution is implemented through the vmsan CLI or SDK",
          owns: [:microvm_create, :microvm_exec, :upload, :download, :snapshot]
        },
        %{
          app: :litter_box_firecracker,
          when:
            "wrapper projects cannot preserve required policy, trace, and workspace semantics",
          owns: [:jailer, :rootfs_lifecycle, :networking, :exec_transport]
        }
      ]
    }
  end

  defp health_row(profile_input) do
    started = System.monotonic_time(:microsecond)

    case Profile.new(profile_input) do
      {:ok, profile} ->
        case LitterBox.status(profile: profile) do
          {:ok, status} ->
            health = List.first(status.backends) || %{}

            {:ok, backend_health} =
              BackendHealth.from_backend(profile.name, profile.backend, health)

            %{
              backend: profile.backend,
              sandbox: profile.name,
              status: status.status,
              duration_us: elapsed_us(started),
              isolation_level: profile.isolation_level,
              runtimes: profile.runtimes,
              network: profile.policy.network,
              transport_model: backend_health.transport_model,
              state_model: backend_health.state_model,
              capabilities: backend_health.capabilities,
              missing_requirements: backend_health.missing_requirements,
              next_action: backend_health.next_action,
              health: health,
              health_summary: backend_health
            }

          {:error, error} ->
            error_row(profile, error, started)
        end

      {:error, error} ->
        %{
          backend: nil,
          sandbox: nil,
          status: :error,
          duration_us: elapsed_us(started),
          error: error_map(error)
        }
    end
  end

  defp latency_row(profile_input) do
    with {:ok, profile} <- Profile.new(profile_input),
         {:ok, request} <- request_for(profile) do
      status = timed(fn -> LitterBox.status(profile: profile) end)
      provision = timed(fn -> LitterBox.provision(profile) end)
      cold_exec = timed(fn -> LitterBox.exec(request, profile: profile) end)
      instance = timing_value(provision)

      session_open =
        timed(fn -> LitterBox.open_session(profile.name, [], profile: profile) end)

      session = timing_value(session_open)

      warm_exec =
        with_instance(instance, fn instance ->
          LitterBox.exec_with_instance(instance, request)
        end)

      session_exec = with_session(session, fn session -> LitterBox.exec(session, request) end)
      session_checkpoint = with_session(session, &LitterBox.checkpoint/1)
      checkpoint = timing_value(session_checkpoint)
      session_restore = with_session_checkpoint(session, checkpoint, &LitterBox.restore/2)
      restored_session = timing_value(session_restore)
      session_close = with_session(restored_session || session, &LitterBox.close_session/1)
      snapshot = with_instance(instance, &LitterBox.snapshot/1)
      reset = with_instance(instance, &LitterBox.reset/1)
      destroy = with_instance(instance, &LitterBox.destroy/1)

      %{
        backend: profile.backend,
        sandbox: profile.name,
        isolation_level: profile.isolation_level,
        status: summarize_timing(status),
        provision: summarize_timing(provision),
        cold_exec: summarize_timing(cold_exec),
        warm_exec: summarize_timing(warm_exec),
        session_open: summarize_timing(session_open),
        session_exec: summarize_timing(session_exec),
        session_checkpoint: summarize_timing(session_checkpoint),
        session_restore: summarize_timing(session_restore),
        session_close: summarize_timing(session_close),
        snapshot: summarize_timing(snapshot),
        reset: summarize_timing(reset),
        destroy: summarize_timing(destroy)
      }
    else
      {:error, error} ->
        %{
          backend: profile_backend(profile_input),
          sandbox: profile_name(profile_input),
          status: :error,
          error: error_map(error)
        }
    end
  end

  defp with_instance(%LitterBox.Instance{} = instance, fun),
    do: timed(fn -> fun.(instance) end)

  defp with_instance(_instance, _fun), do: %{status: :skipped, duration_us: nil, value: nil}

  defp with_session(%LitterBox.Session{} = session, fun), do: timed(fn -> fun.(session) end)

  defp with_session(_session, _fun), do: %{status: :skipped, duration_us: nil, value: nil}

  defp with_session_checkpoint(%LitterBox.Session{} = session, checkpoint, fun)
       when not is_nil(checkpoint),
       do: timed(fn -> fun.(session, checkpoint) end)

  defp with_session_checkpoint(_session, _checkpoint, _fun),
    do: %{status: :skipped, duration_us: nil, value: nil}

  defp error_row(profile, error, started) do
    %{
      backend: profile.backend,
      sandbox: profile.name,
      status: :error,
      duration_us: elapsed_us(started),
      isolation_level: profile.isolation_level,
      runtimes: profile.runtimes,
      network: profile.policy.network,
      transport_model: :unknown,
      state_model: :unknown,
      capabilities: %{exec?: false},
      missing_requirements: [
        %{requirement: :backend_status, message: Map.get(error, :message, inspect(error))}
      ],
      next_action: "Resolve backend status error, then rerun the doctor.",
      error: error_map(error)
    }
  end

  defp timed(fun) do
    started = System.monotonic_time(:microsecond)

    try do
      case fun.() do
        {:ok, value} ->
          %{status: :ok, duration_us: elapsed_us(started), value: value}

        {:error, error} ->
          %{status: :error, duration_us: elapsed_us(started), error: error_map(error)}

        :ok ->
          %{status: :ok, duration_us: elapsed_us(started), value: :ok}
      end
    rescue
      exception ->
        %{
          status: :error,
          duration_us: elapsed_us(started),
          error: %{kind: :unexpected, message: Exception.message(exception), details: %{}}
        }
    end
  end

  defp summarize_timing(%{status: :ok, duration_us: duration_us, value: value}) do
    %{status: :ok, duration_us: duration_us, value: summarize_value(value)}
  end

  defp summarize_timing(%{status: :error, duration_us: duration_us, error: error}) do
    %{status: :error, duration_us: duration_us, error: error}
  end

  defp summarize_timing(%{status: :skipped, duration_us: duration_us}) do
    %{status: :skipped, duration_us: duration_us}
  end

  defp timing_value(%{status: :ok, value: value}), do: value
  defp timing_value(_timing), do: nil

  defp summarize_value(%LitterBox.ExecutionResult{} = result) do
    %{
      status: result.status,
      backend: result.backend,
      isolation_level: result.isolation_level,
      exit_status: result.exit_status
    }
  end

  defp summarize_value(%LitterBox.Instance{} = instance) do
    %{
      state: instance.state,
      backend: instance.backend,
      isolation_level: instance.isolation_level
    }
  end

  defp summarize_value(%{status: status}), do: %{status: status}
  defp summarize_value(:ok), do: %{status: :ok}
  defp summarize_value(_value), do: %{}

  defp request_for(%Profile{backend: :lua, name: name}) do
    LitterBox.ExecutionRequest.new(
      sandbox: name,
      runtime: :lua,
      source: "return 1 + 1",
      timeout_ms: 5_000,
      max_output_bytes: 1_024
    )
  end

  defp request_for(%Profile{name: name}) do
    LitterBox.ExecutionRequest.new(
      sandbox: name,
      runtime: :bash,
      source: "echo latency-ok",
      timeout_ms: 5_000,
      max_output_bytes: 1_024
    )
  end

  defp latency_profiles do
    [
      [name: :just_bash, backend: :just_bash, runtimes: [:bash], network: :disabled],
      [name: :lua, backend: :lua, runtimes: [:lua], network: :disabled]
    ]
  end

  defp elapsed_us(started), do: System.monotonic_time(:microsecond) - started

  defp error_map(error) do
    %{
      kind: Map.get(error, :kind, :error),
      message: Map.get(error, :message, inspect(error)),
      details: Map.get(error, :details, %{})
    }
  end

  defp host do
    {os_family, os_name} = :os.type()

    %{
      os_family: os_family,
      os_name: os_name,
      system_architecture: :erlang.system_info(:system_architecture) |> List.to_string(),
      otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
      elixir_version: System.version()
    }
  end

  defp platform_notes do
    [
      %{platform: :linux, expected_local_backends: [:just_bash, :lua, :docker, :gvisor, :vmsan]},
      %{platform: :macos, expected_local_backends: [:just_bash, :lua, :docker]},
      %{platform: :windows_wsl, expected_local_backends: [:just_bash, :lua, :docker]},
      %{platform: :all, expected_remote_backends: [:remote]}
    ]
  end

  defp profile_backend(input), do: input |> profile_field(:backend) |> normalize_nil()
  defp profile_name(input), do: input |> profile_field(:name) |> normalize_nil()

  defp profile_field(%Profile{} = profile, field), do: Map.get(profile, field)

  defp profile_field(input, field) when is_map(input),
    do: Map.get(input, field, Map.get(input, Atom.to_string(field)))

  defp profile_field(input, field) when is_list(input), do: Keyword.get(input, field)
  defp profile_field(_input, _field), do: nil

  defp normalize_nil(nil), do: :unknown
  defp normalize_nil(value), do: value
end
