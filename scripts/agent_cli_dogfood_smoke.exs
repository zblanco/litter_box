image = System.get_env("RUNIC_SANDBOX_AGENT_CLI_IMAGE", "runic-ai/sandbox-agent-cli:latest")
mcp_port = String.to_integer(System.get_env("RUNIC_SANDBOX_MCP_PORT", "4000"))
model_port = String.to_integer(System.get_env("RUNIC_SANDBOX_MODEL_PROXY_PORT", "4100"))

defmodule LitterBox.AgentCLIDogfoodSmoke do
  def run(image, mcp_port, model_port) do
    with :ok <- require_docker_image(image),
         {:ok, mcp} <- start_server(mcp_port, "mcp-ok"),
         {:ok, model} <- start_server(model_port, "model-ok") do
      try do
        do_run(image, mcp_port, model_port, mcp, model)
      after
        stop_server(mcp)
        stop_server(model)
      end
    else
      {:skip, reason} ->
        IO.puts("agent CLI dogfood smoke skipped: #{reason}")

      {:error, reason} ->
        raise "agent CLI dogfood smoke failed: #{inspect(reason)}"
    end
  end

  defp do_run(image, mcp_port, model_port, mcp, model) do
    name = :"litter_box_agent_cli_dogfood_#{System.unique_integer([:positive])}"

    profiles =
      LitterBox.ConsumerProfiles.agent_cli_pair(
        mcp_port: mcp_port,
        model_proxy_port: model_port,
        image: image,
        dev: [warm: 1, max: 1],
        execution: [warm: 0, max: 1]
      )

    IO.puts("agent CLI dogfood: starting sandbox manager")
    {:ok, manager} = LitterBox.start_link(name: name, sandboxes: profiles)

    try do
      IO.puts("agent CLI dogfood: asserting interactive turn")
      assert_ariston_turn(name, mcp, model)
      IO.puts("agent CLI dogfood: asserting dev/execution roles")
      assert_dev_execution_roles(name)
      IO.puts("agent CLI dogfood: asserting warm pool reuse")
      assert_warm_pool(name)
    after
      GenServer.stop(manager)
    end

    assert_no_litter_box_docker_resources!()
    IO.puts("agent CLI dogfood smoke passed")
  end

  defp assert_ariston_turn(name, mcp, model) do
    IO.puts("agent CLI dogfood: acquiring dev session")
    {:ok, session} = LitterBox.acquire_session(:agent_cli_dev, [], server: name)

    try do
      IO.puts("agent CLI dogfood: checking endpoint env")
      assert_env(session)

      IO.puts("agent CLI dogfood: starting contained CLI process")

      {:ok, process} =
        LitterBox.start_process(
          session,
          runtime: :bash,
          source: cli_script()
        )

      IO.puts("agent CLI dogfood: writing stdin")
      :ok = LitterBox.write_process_stdin(process, "interactive-turn\n")
      IO.puts("agent CLI dogfood: collecting process output")
      output = await_turn_output(session)

      unless output =~ "cli-ready" and output =~ "turn=interactive-turn" and
               output =~ "mcp=mcp-ok" and output =~ "model=model-ok" and
               output =~ "public_denied=ok" do
        raise "agent CLI turn output did not prove MCP/model callbacks and denied public egress: #{inspect(output)}"
      end

      unless request_count(mcp) > 0 and request_count(model) > 0 do
        raise "host MCP/model proxies did not observe callbacks"
      end
    after
      _ = LitterBox.release_session(session, server: name)
    end
  end

  defp assert_dev_execution_roles(name) do
    {:ok, dev} = LitterBox.acquire_session(:agent_cli_dev, [], server: name)

    try do
      {:ok, _ref} = LitterBox.write_file(dev, "promotion/draft.txt", "generated-in-dev")
      {:ok, draft} = LitterBox.read_file(dev, "promotion/draft.txt")

      {:ok, execution} = LitterBox.acquire_session(:agent_cli_execution, [], server: name)

      try do
        {:ok, _ref} = LitterBox.write_file(execution, "promotion/draft.txt", draft)

        {:ok, proof} =
          LitterBox.exec(execution,
            runtime: :bash,
            source: "test \"$(cat promotion/draft.txt)\" = generated-in-dev && printf proof-ok"
          )

        unless proof.status == :pass and proof.stdout == "proof-ok" do
          raise "execution sandbox proof failed: #{inspect(proof)}"
        end
      after
        _ = LitterBox.release_session(execution, server: name)
      end
    after
      _ = LitterBox.release_session(dev, server: name)
    end

    {:ok, status} = LitterBox.status(server: name)
    [%{id: reset_id}] = status.sandboxes.agent_cli_execution.sessions
    {:ok, execution_again} = LitterBox.acquire_session(:agent_cli_execution, [], server: name)

    try do
      unless execution_again.id == reset_id do
        raise "execution pool did not keep the reset warm replacement"
      end

      case LitterBox.read_file(execution_again, "promotion/draft.txt") do
        {:ok, "generated-in-dev"} ->
          raise "execution sandbox reused unsafe state after reset-on-checkin"

        _other ->
          :ok
      end
    after
      _ = LitterBox.release_session(execution_again, server: name)
    end
  end

  defp assert_warm_pool(name) do
    {:ok, status} = LitterBox.status(server: name)
    assert_ready_pool!(status, :agent_cli_dev)

    {:ok, first} = LitterBox.acquire_session(:agent_cli_dev, [], server: name)
    first_container = first.metadata.container_name

    try do
      {:ok, status} = LitterBox.status(server: name)
      [checked_out] = status.sandboxes.agent_cli_dev.sessions

      unless checked_out.checkout_source == :warm and
               is_integer(checked_out.last_checkout_latency_ms) do
        raise "warm checkout evidence missing: #{inspect(checked_out)}"
      end
    after
      _ = LitterBox.release_session(first, server: name)
    end

    {:ok, second} = LitterBox.acquire_session(:agent_cli_dev, [], server: name)

    try do
      unless second.id == first.id and second.metadata.container_name == first_container do
        raise "warm pool did not reuse the dev sandbox session"
      end
    after
      _ = LitterBox.release_session(second, server: name)
    end
  end

  defp assert_env(session) do
    {:ok, result} =
      LitterBox.exec(session,
        runtime: :bash,
        source: "printf '%s\\n%s\\n' \"$RUNIC_MCP_URL\" \"$RUNIC_MODEL_PROXY_URL\""
      )

    unless result.stdout =~ "http://host.docker.internal:" do
      raise "agent CLI env was not injected: #{inspect(result.stdout)}"
    end
  end

  defp cli_script do
    """
    set -eu
    mkdir -p dogfood
    log=dogfood/turn.log
    printf 'cli-ready\\n' > "$log"
    IFS= read -r turn
    mcp=$(curl -fsS --max-time 5 "$RUNIC_MCP_URL/mcp?turn=$turn")
    model=$(curl -fsS --max-time 5 -X POST "$RUNIC_MODEL_PROXY_URL/v1/responses" -H 'content-type: application/json' -d "{\\"input\\":\\"$turn\\"}")
    if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(2); sys.exit(0 if s.connect_ex(("93.184.216.34", 80)) == 0 else 1)'
    then
      printf 'public_denied=failed\\n' >> "$log"
      exit 2
    else
      printf 'public_denied=ok\\n' >> "$log"
    fi
    printf 'turn=%s\\n' "$turn" >> "$log"
    printf 'mcp=%s\\n' "$mcp" >> "$log"
    printf 'model=%s\\n' "$model" >> "$log"
    """
  end

  defp await_turn_output(session, attempts \\ 100)

  defp await_turn_output(session, attempts) when attempts > 0 do
    case LitterBox.read_file(session, "dogfood/turn.log") do
      {:ok, output} ->
        if output =~ "model=model-ok" do
          output
        else
          Process.sleep(100)
          await_turn_output(session, attempts - 1)
        end

      _other ->
        Process.sleep(100)
        await_turn_output(session, attempts - 1)
    end
  end

  defp await_turn_output(session, 0) do
    case LitterBox.read_file(session, "dogfood/turn.log") do
      {:ok, output} -> output
      other -> raise "agent CLI turn log was not produced: #{inspect(other)}"
    end
  end

  defp assert_ready_pool!(status, sandbox) do
    pool_status = status.sandboxes[sandbox].pool_status

    unless pool_status.ready >= 1 do
      raise "expected a ready warm #{sandbox} session, got #{inspect(pool_status)}"
    end
  end

  defp require_docker_image(image) do
    case System.find_executable("docker") do
      nil ->
        {:skip, "docker executable is not available"}

      docker ->
        case System.cmd(docker, ["image", "inspect", image], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          _other -> {:skip, "docker image is not available (#{image})"}
        end
    end
  end

  defp start_server(port, body) do
    case :gen_tcp.listen(port, [:binary, active: false, packet: :raw, reuseaddr: true]) do
      {:ok, listen} ->
        {:ok, requests} = Agent.start_link(fn -> [] end)
        pid = spawn_link(fn -> accept_loop(listen, body, requests) end)
        {:ok, %{listen: listen, pid: pid, requests: requests, port: port}}

      {:error, :eaddrinuse} ->
        {:skip, "host port #{port} is already in use"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp accept_loop(listen, body, requests) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        _ = handle_socket(socket, body, requests)
        accept_loop(listen, body, requests)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listen, body, requests)
    end
  end

  defp handle_socket(socket, body, requests) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, request} ->
        Agent.update(requests, &[request | &1])

        response = [
          "HTTP/1.1 200 OK\r\n",
          "content-type: text/plain\r\n",
          "content-length: ",
          Integer.to_string(byte_size(body)),
          "\r\nconnection: close\r\n\r\n",
          body
        ]

        :gen_tcp.send(socket, response)

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp stop_server(%{listen: listen, pid: pid, requests: requests}) do
    :gen_tcp.close(listen)

    if Process.alive?(pid) do
      Process.exit(pid, :normal)
    end

    Agent.stop(requests)
  end

  defp request_count(%{requests: requests}) do
    Agent.get(requests, &length/1)
  end

  defp assert_no_litter_box_docker_resources! do
    docker = System.find_executable("docker")

    containers =
      docker
      |> docker_lines(["ps", "-a", "--filter", "name=runic-sandbox", "--format", "{{.Names}}"])
      |> Enum.reject(&(&1 == ""))

    networks =
      docker
      |> docker_lines([
        "network",
        "ls",
        "--filter",
        "name=runic-sandbox",
        "--format",
        "{{.Name}}"
      ])
      |> Enum.reject(&(&1 == ""))

    unless containers == [] and networks == [] do
      raise "runic sandbox docker resources leaked: #{inspect(%{containers: containers, networks: networks})}"
    end
  end

  defp docker_lines(nil, _args), do: []

  defp docker_lines(docker, args) do
    case System.cmd(docker, args, stderr_to_stdout: true) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _other -> []
    end
  end
end

LitterBox.AgentCLIDogfoodSmoke.run(image, mcp_port, model_port)
