image = System.get_env("RUNIC_SANDBOX_DOCKER_IMAGE", "runic-ai/sandbox:elixir-python-node")

docker_image_available? =
  case System.find_executable("docker") do
    nil ->
      false

    docker ->
      match?(
        {_output, 0},
        System.cmd(docker, ["image", "inspect", image], stderr_to_stdout: true)
      )
  end

if docker_image_available? do
  profile =
    LitterBox.Profile.new!(
      name: :local_code,
      backend: :docker,
      runtimes: [:bash],
      network: :disabled,
      image: image
    )

  {:ok, session} = LitterBox.open_session(:local_code, [], profile: profile)

  try do
    {:ok, _ref} = LitterBox.write_file(session, "checkpoint.txt", "before")
    {:ok, checkpoint} = LitterBox.checkpoint(session, id: "smoke")

    unless checkpoint.metadata.kind == :filesystem and
             checkpoint.metadata.preserves.process_memory == false do
      raise "docker checkpoint metadata overclaims preservation: #{inspect(checkpoint.metadata)}"
    end

    {:ok, _ref} = LitterBox.write_file(session, "checkpoint.txt", "after")
    {:ok, restored} = LitterBox.restore(session, checkpoint)
    {:ok, "before"} = LitterBox.read_file(restored, "checkpoint.txt")

    IO.puts("docker filesystem checkpoint smoke passed")
  after
    _ = LitterBox.close_session(session)
  end
else
  IO.puts("docker filesystem checkpoint smoke skipped: image not available (#{image})")
end
