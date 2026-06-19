defmodule LitterBox.CapabilityReport do
  alias LitterBox.Capabilities
  alias LitterBox.Profile

  @backends [
    {:docker, process_host_expected?: true},
    {:gvisor, process_host_expected?: true},
    {:vmsan, process_host_expected?: true},
    {:sprites, process_host_expected?: true},
    {:remote, process_host_expected?: false},
    {:just_bash, process_host_expected?: false},
    {:lua, process_host_expected?: false}
  ]

  def run do
    report =
      Enum.map(@backends, fn {backend, expectations} -> backend_report(backend, expectations) end)

    IO.puts(Jason.encode!(%{generated_at: DateTime.utc_now(), backends: report}, pretty: true))
  end

  defp backend_report(backend, expectations) do
    profile = profile(backend)

    status =
      case LitterBox.status(profile: profile) do
        {:ok, status} -> status
        {:error, error} -> %{error: error.message, details: error.details}
      end

    backend_status = status |> Map.get(:backends, []) |> List.wrap() |> List.first(%{})
    capabilities = Map.get(backend_status, :capabilities, profile_capabilities(profile))
    available? = Map.get(backend_status, :available?, false)

    %{
      backend: backend,
      available?: available?,
      process_host?: Capabilities.process_host?(capabilities),
      live_process_stream?: Capabilities.live_process_stream?(capabilities),
      workspace_persistent?: Capabilities.workspace_persistent?(capabilities),
      service_host?: Capabilities.service_host?(capabilities),
      snapshot_modes: Capabilities.snapshot_modes(capabilities),
      state_tier: Capabilities.state_tier(capabilities),
      expected_full_process_host?: Keyword.fetch!(expectations, :process_host_expected?),
      limited?: limited?(backend, capabilities, available?),
      limitation: limitation(backend, capabilities, available?),
      missing_requirements: Map.get(backend_status, :missing_requirements, []),
      diagnostics: Map.get(backend_status, :diagnostics, [])
    }
  end

  defp profile(:docker) do
    {_name, config} =
      LitterBox.ConsumerProfiles.agent_cli_dev(
        image:
          System.get_env("RUNIC_SANDBOX_AGENT_CLI_IMAGE", "runic-ai/sandbox-agent-cli:latest")
      )

    Profile.from_named_config(:agent_cli_dev, config) |> elem(1)
  end

  defp profile(:gvisor) do
    docker = profile(:docker)
    %{docker | backend: :gvisor, isolation_level: :gvisor}
  end

  defp profile(:vmsan) do
    Profile.new!(
      name: :local_code,
      backend: :vmsan,
      runtimes: [:bash],
      network: :disabled,
      backend_options: %{sudo?: true}
    )
  end

  defp profile(:sprites) do
    Profile.new!(
      name: :sprites_stateful,
      backend: :sprites,
      runtimes: [:bash],
      network: :restricted,
      backend_options: %{
        sprite: System.get_env("SPRITES_SMOKE_SPRITE", "runic-capability-report")
      }
    )
  end

  defp profile(:remote) do
    Profile.new!(name: :remote_code, backend: :remote, runtimes: [:bash], network: :restricted)
  end

  defp profile(:just_bash) do
    Profile.new!(name: :local_code, backend: :just_bash, runtimes: [:bash], network: :disabled)
  end

  defp profile(:lua) do
    Profile.new!(name: :lua_code, backend: :lua, runtimes: [:lua], network: :disabled)
  end

  defp profile_capabilities(profile) do
    profile
    |> Map.get(:metadata, %{})
    |> Map.get(:capabilities, Capabilities.new!())
  end

  defp limited?(_backend, _capabilities, false), do: true

  defp limited?(backend, capabilities, true) when backend in [:just_bash, :lua, :remote] do
    not Capabilities.process_host?(capabilities)
  end

  defp limited?(_backend, capabilities, true), do: not Capabilities.process_host?(capabilities)

  defp limitation(backend, _capabilities, false), do: "#{backend} is not available on this host"
  defp limitation(:just_bash, _capabilities, true), do: "one-shot host-local command backend"
  defp limitation(:lua, _capabilities, true), do: "in-process deterministic snippet backend"

  defp limitation(:remote, capabilities, true) do
    if Capabilities.process_host?(capabilities),
      do: nil,
      else: "remote/Fly process hosting requires native machine lifecycle or sidecar integration"
  end

  defp limitation(_backend, capabilities, true) do
    if Capabilities.process_host?(capabilities),
      do: nil,
      else: "process host capability is unavailable"
  end
end

LitterBox.CapabilityReport.run()
