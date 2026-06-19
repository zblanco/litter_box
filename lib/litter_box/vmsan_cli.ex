defmodule LitterBox.VmsanCLI do
  @moduledoc false

  alias LitterBox.Error

  @spec command([String.t()], keyword()) :: {String.t(), [String.t()]}
  def command(args, opts \\ []) when is_list(args) do
    executable = opts |> Keyword.get(:executable, "vmsan") |> to_string()

    argv =
      if Keyword.get(opts, :json?, true) do
        ["--json" | Enum.map(args, &to_string/1)]
      else
        Enum.map(args, &to_string/1)
      end

    if Keyword.get(opts, :sudo?, false) do
      path = Keyword.get(opts, :path, System.get_env("PATH") || "")
      {"sudo", ["-n", "env", "PATH=#{path}", executable | argv]}
    else
      {executable, argv}
    end
  end

  @spec run_json([String.t()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run_json(args, opts \\ []) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    {command, argv} = command(args, opts)

    task = Task.async(fn -> runner.(command, argv, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_status}} when is_binary(output) and is_integer(exit_status) ->
        handle_output(command, argv, output, exit_status)

      nil ->
        {:error,
         Error.timeout("vmsan command timed out",
           source: __MODULE__,
           details: %{command: command, args: argv, timeout_ms: timeout_ms}
         )}

      {:ok, other} ->
        {:error,
         Error.validation("unexpected vmsan command result",
           source: __MODULE__,
           details: %{command: command, args: argv, result: inspect(other)}
         )}
    end
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  @spec create_args(keyword() | map()) :: [String.t()]
  def create_args(opts \\ []) do
    opts = input_map(opts)

    ["create"]
    |> maybe_arg("--vcpus", get(opts, :vcpus))
    |> maybe_arg("--memory", get(opts, :memory))
    |> maybe_arg("--kernel", get(opts, :kernel))
    |> maybe_arg("--rootfs", get(opts, :rootfs))
    |> maybe_arg("--runtime", get(opts, :runtime))
    |> maybe_arg("--project", get(opts, :project))
    |> maybe_arg("--disk", get(opts, :disk))
    |> maybe_arg("--timeout", get(opts, :timeout))
    |> maybe_arg("--snapshot", get(opts, :snapshot))
    |> append_network_args(input_network_policy(opts))
    |> maybe_arg("--bandwidth", get(opts, :bandwidth))
  end

  @spec exec_args(String.t(), [String.t()], keyword() | map()) :: [String.t()]
  def exec_args(vm_id, argv, opts \\ []) when is_binary(vm_id) and is_list(argv) do
    opts = input_map(opts)

    ["exec"]
    |> maybe_arg("--workdir", get(opts, :workdir))
    |> env_args(get(opts, :env))
    |> maybe_bool("--sudo", get(opts, :sudo?))
    |> Kernel.++([vm_id, "--" | Enum.map(argv, &to_string/1)])
  end

  @spec exec_interactive_args(String.t(), [String.t()], keyword() | map()) :: [String.t()]
  def exec_interactive_args(vm_id, argv, opts \\ []) when is_binary(vm_id) and is_list(argv) do
    opts = input_map(opts)

    ["exec", "--interactive"]
    |> maybe_bool("--tty", get(opts, :tty?))
    |> maybe_bool("--no-extend-timeout", get(opts, :extend_timeout?) == false)
    |> maybe_arg("--workdir", get(opts, :workdir))
    |> env_args(get(opts, :env))
    |> maybe_bool("--sudo", get(opts, :sudo?))
    |> Kernel.++([vm_id, "--" | Enum.map(argv, &to_string/1)])
  end

  @spec upload_args(String.t(), [Path.t()], keyword() | map()) :: [String.t()]
  def upload_args(vm_id, paths, opts \\ []) when is_binary(vm_id) and is_list(paths) do
    opts = input_map(opts)

    ["upload"]
    |> maybe_arg("--dest", get(opts, :dest))
    |> Kernel.++([vm_id | Enum.map(paths, &to_string/1)])
  end

  @spec download_args(String.t(), Path.t(), keyword() | map()) :: [String.t()]
  def download_args(vm_id, remote_path, opts \\ []) when is_binary(vm_id) do
    opts = input_map(opts)

    ["download"]
    |> maybe_arg("--dest", get(opts, :dest))
    |> Kernel.++([vm_id, to_string(remote_path)])
  end

  @spec network_args(String.t(), keyword() | map()) :: [String.t()]
  def network_args(vm_id, opts) when is_binary(vm_id) do
    opts = input_map(opts)
    ["network"] |> append_network_args(opts) |> Kernel.++([vm_id])
  end

  @spec snapshot_create_args(String.t(), keyword() | map()) :: [String.t()]
  def snapshot_create_args(vm_id, opts \\ []) when is_binary(vm_id) do
    opts = input_map(opts)

    ["snapshot", "create"]
    |> maybe_bool("--no-resume", get(opts, :resume?) == false)
    |> Kernel.++([vm_id])
  end

  @spec remove_args(String.t()) :: [String.t()]
  def remove_args(vm_id), do: ["remove", "--force", to_string(vm_id)]

  defp handle_output(command, argv, output, exit_status) do
    {event, stream_output} = parse_output(output)

    cond do
      sudo_password_required?(command, output) ->
        {:error, sudo_password_error(command, argv, output, exit_status)}

      is_map(event) and Map.has_key?(event, "error") ->
        {:error, event_error(command, argv, output, exit_status, event)}

      is_map(event) and exit_status == 0 ->
        {:ok,
         %{
           command: command,
           args: argv,
           exit_status: exit_status,
           output: output,
           stream_output: stream_output,
           event: event
         }}

      is_map(event) ->
        {:error,
         Error.validation("vmsan command failed",
           source: __MODULE__,
           details: %{
             command: command,
             args: argv,
             exit_status: exit_status,
             event: event,
             output_preview: String.slice(output, 0, 1_000)
           }
         )}

      true ->
        {:error,
         Error.validation("vmsan command did not emit JSON",
           source: __MODULE__,
           details: %{
             command: command,
             args: argv,
             exit_status: exit_status,
             output_preview: String.slice(output, 0, 1_000)
           }
         )}
    end
  end

  defp event_error(command, argv, output, exit_status, %{"error" => error}) do
    Error.validation(Map.get(error, "message", "vmsan command failed"),
      source: __MODULE__,
      details: %{
        command: command,
        args: argv,
        exit_status: exit_status,
        code: Map.get(error, "code"),
        fix: Map.get(error, "fix") || get_in(error, ["data", "fix"]),
        output_preview: String.slice(output, 0, 1_000)
      }
    )
  end

  defp sudo_password_required?("sudo", output) do
    String.contains?(output, "sudo: a password is required") or
      String.contains?(output, "sudo: a terminal is required")
  end

  defp sudo_password_required?(_command, _output), do: false

  defp sudo_password_error(command, argv, output, exit_status) do
    Error.provider("vmsan command requires passwordless sudo",
      source: __MODULE__,
      details: %{
        command: command,
        args: argv,
        exit_status: exit_status,
        fix:
          "Configure passwordless sudo for vmsan create/remove or run the VM lifecycle from a privileged wrapper.",
        output_preview: String.slice(output, 0, 1_000)
      }
    )
  end

  defp parse_output(output) do
    lines = String.split(output, "\n", trim: true)

    json_index =
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {line, index} ->
        case Jason.decode(line) do
          {:ok, %{}} -> index
          _other -> nil
        end
      end)

    {event, stream_lines} =
      case json_index do
        nil ->
          {nil, lines}

        index ->
          {line, rest} = List.pop_at(lines, index)
          {:ok, event} = Jason.decode(line)
          {event, rest}
      end

    {event, stream_lines |> Enum.reject(&(&1 == "")) |> Enum.join("\n") |> add_newline()}
  end

  defp add_newline(""), do: ""
  defp add_newline(value), do: value <> "\n"

  defp append_network_args(args, opts) do
    args
    |> maybe_arg("--network-policy", get(opts, :network_policy))
    |> maybe_arg("--allowed-domain", comma(get(opts, :allowed_domains)))
    |> maybe_arg("--allowed-cidr", comma(get(opts, :allowed_cidrs)))
    |> maybe_arg("--denied-cidr", comma(get(opts, :denied_cidrs)))
  end

  defp input_network_policy(opts),
    do: Map.take(opts, [:network_policy, :allowed_domains, :allowed_cidrs, :denied_cidrs])

  defp maybe_arg(args, _flag, nil), do: args
  defp maybe_arg(args, _flag, ""), do: args
  defp maybe_arg(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_bool(args, _flag, value) when value in [nil, false], do: args
  defp maybe_bool(args, flag, true), do: args ++ [flag]

  defp env_args(args, env) when env in [nil, %{}, []], do: args

  defp env_args(args, env) do
    env
    |> input_map()
    |> Enum.reduce(args, fn {key, value}, acc -> acc ++ ["--env", "#{key}=#{value}"] end)
  end

  defp comma(nil), do: nil
  defp comma(value) when is_binary(value), do: value
  defp comma(value) when is_list(value), do: Enum.map_join(value, ",", &to_string/1)
  defp comma(value), do: to_string(value)

  defp input_map(value) when is_map(value), do: value
  defp input_map(value) when is_list(value), do: Map.new(value)
  defp input_map(_value), do: %{}

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
