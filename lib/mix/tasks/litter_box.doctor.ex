defmodule Mix.Tasks.LitterBox.Doctor do
  @moduledoc """
  Inspect host and provider readiness for LitterBox backends.

      mix litter_box.doctor
      mix litter_box.doctor --format json
  """

  use Mix.Task

  @shortdoc "Inspect LitterBox host/provider readiness"

  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [format: :string])

    if invalid != [] do
      Mix.raise("invalid litter_box.doctor options: #{inspect(invalid)}")
    end

    report = LitterBox.Reports.doctor()

    case Keyword.get(opts, :format, "text") do
      "json" -> Mix.shell().info(Jason.encode!(json_safe(report), pretty: true))
      "text" -> print_text(report)
      other -> Mix.raise("unsupported doctor format: #{other}")
    end
  end

  defp print_text(report) do
    host = report.host_probe.host
    vmsan = report.host_probe.vmsan
    sprites = report.host_probe.sprites

    Mix.shell().info("Host")
    Mix.shell().info("os=#{host.os_family}/#{host.os_name} arch=#{host.system_architecture}")

    Mix.shell().info(
      "kvm_exists=#{host.kvm.exists?} kvm_rw=#{host.kvm.readable? and host.kvm.writable?}"
    )

    Mix.shell().info("kvm_modules=#{inspect(host.kvm_modules)}")

    Mix.shell().info("\nvmsan")
    Mix.shell().info("installed=#{vmsan.installed?} version=#{vmsan.version || "unknown"}")
    Mix.shell().info("available=#{vmsan.available?} summary=#{inspect(vmsan.doctor.summary)}")

    Enum.each(vmsan.doctor.missing_requirements, fn missing ->
      Mix.shell().info("missing=#{missing.requirement} #{missing.message}")
    end)

    Mix.shell().info("\nSprites")

    Mix.shell().info(
      "installed=#{sprites.installed?} auth_configured=#{sprites.auth_configured?} token=#{sprites.token_env.value}"
    )

    Enum.each(sprites.diagnostics, fn diagnostic ->
      Mix.shell().info("diagnostic=#{diagnostic.message}")
    end)
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%_struct{} = value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, json_safe(value)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value), do: value
end
