defmodule LitterBox.HostProbe do
  @moduledoc """
  Local host and provider readiness probes used by doctor/report tasks.
  """

  @vmsan_missing_requirements %{
    "KVM" => :kvm,
    "TUN device" => :tun,
    "Disk space" => :disk_space,
    "Default interface" => :default_interface,
    "nftables kernel" => :nftables_kernel,
    "Host firewall" => :host_firewall,
    "Jailer filesystem" => :jailer_filesystem,
    "Firecracker" => :firecracker,
    "Jailer" => :jailer,
    "Agent" => :vmsan_agent,
    "vmsan-nftables" => :vmsan_nftables,
    "Kernel" => :kernel_image,
    "Rootfs (base)" => :rootfs_image
  }
  @sprites_token_env "SPRITES_TOKEN"

  @spec collect(keyword()) :: map()
  def collect(opts \\ []) do
    commands = Keyword.get(opts, :commands, &System.cmd/3)
    env = Keyword.get(opts, :env, &System.get_env/1)

    %{
      generated_at: DateTime.utc_now(),
      host: host(commands),
      docker: docker(commands),
      vmsan: vmsan(commands),
      sprites: sprites(commands, env)
    }
  end

  @spec vmsan_doctor(keyword()) :: map()
  def vmsan_doctor(opts \\ []) do
    commands = Keyword.get(opts, :commands, &System.cmd/3)

    case executable(commands, "vmsan") do
      nil ->
        %{
          executable: nil,
          available?: false,
          status: :unavailable,
          checks: [],
          missing_requirements: [
            %{requirement: :vmsan, message: "vmsan executable is unavailable"}
          ],
          diagnostics: [%{message: "vmsan executable is unavailable", details: %{}}],
          summary: %{passed: 0, failed: 1, total: 1}
        }

      path ->
        case run(commands, path, ["doctor", "--json"], stderr_to_stdout: true) do
          {:ok, output, 0} ->
            parse_vmsan_doctor(output, executable: path)

          {:ok, output, status} ->
            parse_vmsan_doctor(output, executable: path, exit_status: status)

          {:error, error} ->
            %{
              executable: path,
              available?: false,
              status: :unavailable,
              checks: [],
              missing_requirements: [%{requirement: :vmsan_doctor, message: error.message}],
              diagnostics: [%{message: error.message, details: error.details}],
              summary: %{passed: 0, failed: 1, total: 1}
            }
        end
    end
  end

  @spec parse_vmsan_doctor(binary(), keyword()) :: map()
  def parse_vmsan_doctor(output, opts \\ []) when is_binary(output) do
    executable = Keyword.get(opts, :executable)
    exit_status = Keyword.get(opts, :exit_status, 0)

    case Jason.decode(output) do
      {:ok, %{"checks" => checks} = decoded} when is_list(checks) ->
        checks = Enum.map(checks, &normalize_vmsan_check/1)
        missing = vmsan_missing_requirements(checks)
        failed = Enum.count(checks, &(&1.status == :fail))

        %{
          executable: executable,
          available?: failed == 0,
          status: if(failed == 0, do: :available, else: :unavailable),
          checks: checks,
          missing_requirements: missing,
          diagnostics:
            Enum.map(missing, &%{message: &1.message, details: %{requirement: &1.requirement}}),
          summary: normalize_summary(Map.get(decoded, "summary"), checks),
          exit_status: exit_status,
          raw_path: Map.get(decoded, "path"),
          timestamp: Map.get(decoded, "timestamp")
        }

      {:ok, decoded} ->
        invalid_vmsan_doctor(executable, exit_status, "unexpected vmsan doctor JSON", decoded)

      {:error, error} ->
        invalid_vmsan_doctor(executable, exit_status, "invalid vmsan doctor JSON", %{
          error: Exception.message(error),
          output_preview: String.slice(output, 0, 1_000)
        })
    end
  end

  defp host(commands) do
    {os_family, os_name} = :os.type()

    kvm_path = "/dev/kvm"
    tun_path = "/dev/net/tun"

    %{
      os_family: os_family,
      os_name: os_name,
      system_architecture: :erlang.system_info(:system_architecture) |> List.to_string(),
      otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
      elixir_version: System.version(),
      uname: command_output(commands, "uname", ["-a"]),
      virtualization: command_output(commands, "systemd-detect-virt", []),
      cpu_virtualization_flags: cpu_virtualization_flags(),
      kvm: file_access(kvm_path),
      tun: file_access(tun_path),
      kvm_modules: loaded_modules(["kvm", "kvm_amd", "kvm_intel"]),
      kvm_ok: command_output(commands, "kvm-ok", [])
    }
  end

  defp docker(commands) do
    executable = executable(commands, "docker")

    %{
      executable: executable,
      available?: is_binary(executable),
      runtimes:
        if(executable,
          do: command_output(commands, executable, ["info", "--format", "{{json .Runtimes}}"]),
          else: nil
        )
    }
  end

  defp vmsan(commands) do
    executable = executable(commands, "vmsan")
    doctor = vmsan_doctor(commands: commands)

    %{
      executable: executable,
      version: if(executable, do: command_output(commands, executable, ["--version"]), else: nil),
      available?: doctor.available?,
      installed?: is_binary(executable),
      doctor: doctor
    }
  end

  defp sprites(commands, env) do
    executable = executable(commands, "sprite") || executable(commands, "sprites")
    token_present? = present?(env.(@sprites_token_env))
    help = if(executable, do: command_output(commands, executable, ["--help"]), else: nil)

    %{
      executable: executable,
      installed?: is_binary(executable),
      auth_configured?: token_present?,
      token_env: %{name: @sprites_token_env, present?: token_present?, value: :redacted},
      help_available?: is_binary(help),
      commands: sprite_commands(help),
      status: if(executable && token_present?, do: :available, else: :unavailable),
      diagnostics: sprite_diagnostics(executable, token_present?)
    }
  end

  defp executable(commands, name) do
    case run(commands, "sh", ["-c", "command -v #{shell_escape(name)}"], stderr_to_stdout: true) do
      {:ok, output, 0} ->
        output
        |> String.trim()
        |> case do
          "" -> nil
          path -> path
        end

      _other ->
        nil
    end
  end

  defp command_output(commands, command, args) do
    case run(commands, command, args, stderr_to_stdout: true) do
      {:ok, output, _status} -> String.trim(output)
      {:error, _error} -> nil
    end
  end

  defp run(commands, command, args, opts) do
    case commands.(command, args, opts) do
      {output, status} when is_binary(output) and is_integer(status) ->
        {:ok, output, status}

      other ->
        {:error,
         %{message: "unexpected command result", details: %{command: command, result: other}}}
    end
  rescue
    exception ->
      {:error, %{message: Exception.message(exception), details: %{command: command, args: args}}}
  end

  defp normalize_vmsan_check(check) when is_map(check) do
    %{
      category: Map.get(check, "category"),
      name: Map.get(check, "name"),
      status: normalize_status(Map.get(check, "status")),
      detail: Map.get(check, "detail")
    }
  end

  defp normalize_status("pass"), do: :pass
  defp normalize_status("fail"), do: :fail
  defp normalize_status("warn"), do: :warn
  defp normalize_status(value) when is_atom(value), do: value
  defp normalize_status(_value), do: :unknown

  defp vmsan_missing_requirements(checks) do
    checks
    |> Enum.filter(&(&1.status == :fail))
    |> Enum.map(fn check ->
      %{
        requirement:
          Map.get(@vmsan_missing_requirements, check.name, normalize_requirement(check.name)),
        message: "#{check.name}: #{check.detail}",
        category: check.category,
        detail: check.detail
      }
    end)
  end

  defp normalize_summary(%{"passed" => passed, "failed" => failed, "total" => total}, _checks),
    do: %{passed: passed, failed: failed, total: total}

  defp normalize_summary(_summary, checks) do
    passed = Enum.count(checks, &(&1.status == :pass))
    failed = Enum.count(checks, &(&1.status == :fail))
    %{passed: passed, failed: failed, total: length(checks)}
  end

  defp invalid_vmsan_doctor(executable, exit_status, message, details) do
    %{
      executable: executable,
      available?: false,
      status: :unavailable,
      checks: [],
      missing_requirements: [%{requirement: :vmsan_doctor, message: message}],
      diagnostics: [%{message: message, details: details}],
      summary: %{passed: 0, failed: 1, total: 1},
      exit_status: exit_status
    }
  end

  defp file_access(path) do
    %{
      path: path,
      exists?: File.exists?(path),
      readable?: File.exists?(path) and File.stat!(path).access in [:read, :read_write],
      writable?: File.exists?(path) and File.stat!(path).access in [:write, :read_write]
    }
  rescue
    _exception -> %{path: path, exists?: File.exists?(path), readable?: false, writable?: false}
  end

  defp loaded_modules(names) do
    modules =
      "/proc/modules"
      |> File.read()
      |> case do
        {:ok, contents} -> contents
        {:error, _error} -> ""
      end

    Map.new(names, fn name -> {module_key(name), String.contains?(modules, "#{name} ")} end)
  end

  defp module_key("kvm"), do: :kvm
  defp module_key("kvm_amd"), do: :kvm_amd
  defp module_key("kvm_intel"), do: :kvm_intel
  defp module_key(name), do: name

  defp cpu_virtualization_flags do
    "/proc/cpuinfo"
    |> File.read()
    |> case do
      {:ok, contents} ->
        flags = Regex.run(~r/^flags\s*:\s*(.+)$/m, contents, capture: :all_but_first)

        case flags do
          [line] -> %{svm?: has_flag?(line, "svm"), vmx?: has_flag?(line, "vmx")}
          _other -> %{svm?: false, vmx?: false}
        end

      {:error, _error} ->
        %{svm?: false, vmx?: false}
    end
  end

  defp has_flag?(line, flag), do: line |> String.split() |> Enum.member?(flag)

  defp sprite_diagnostics(nil, _token_present?),
    do: [%{message: "sprite executable is unavailable", details: %{}}]

  defp sprite_diagnostics(_executable, false),
    do: [
      %{message: "#{@sprites_token_env} is not configured", details: %{env: @sprites_token_env}}
    ]

  defp sprite_diagnostics(_executable, true), do: []

  defp sprite_commands(help) when is_binary(help) do
    ~w(login logout exec console create use list checkpoint restore destroy proxy api url upgrade org auth)
    |> Enum.filter(&String.contains?(help, &1))
  end

  defp sprite_commands(_help), do: []

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp normalize_requirement(nil), do: :unknown

  defp normalize_requirement(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp shell_escape(value), do: String.replace(value, "'", "'\\''")
end
