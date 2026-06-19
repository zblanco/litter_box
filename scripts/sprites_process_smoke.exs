env = &System.get_env/1
sprite = env.("SPRITES_SMOKE_SPRITE")
token = env.("SPRITES_TOKEN") || env.("SPRITE_TOKEN")
websocat = System.find_executable("websocat")

cond do
  not is_binary(sprite) or sprite == "" ->
    IO.puts("sprites process smoke skipped: set SPRITES_SMOKE_SPRITE")

  not is_binary(token) or token == "" ->
    IO.puts("sprites process smoke skipped: set SPRITES_TOKEN or SPRITE_TOKEN")

  not is_binary(websocat) ->
    IO.puts("sprites process smoke skipped: install websocat for the default WebSocket adapter")

  true ->
    profile =
      LitterBox.Profile.new!(
        name: :sprites_code,
        backend: :sprites,
        runtimes: [:bash],
        network: :restricted,
        backend_options: %{
          sprite: sprite,
          create_policy: :use_existing
        }
      )

    env_fun = fn
      "SPRITES_TOKEN" -> token
      "SPRITE_TOKEN" -> token
      name -> System.get_env(name)
    end

    {:ok, session} = LitterBox.open_session(:sprites_code, [], profile: profile, env: env_fun)

    {:ok, process} =
      LitterBox.start_process(session,
        [runtime: :bash, source: "printf sprites-process-ok"],
        env: env_fun
      )

    {:ok, events} = LitterBox.process_events(process)
    output = events |> Enum.map_join("", &(get_in(&1.payload, [:chunk]) || ""))

    unless output =~ "sprites-process-ok" do
      raise "sprites process smoke did not observe expected output: #{inspect(output)}"
    end

    IO.puts("sprites process smoke passed")
end
