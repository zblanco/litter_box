profile =
  LitterBox.Profile.new!(
    name: :local_code,
    backend: :vmsan,
    runtimes: [:bash],
    network: :disabled,
    backend_options: %{
      sudo?: true
    }
  )

case LitterBox.status(profile: profile) do
  {:ok, %{backends: [%{available?: true}]}} ->
    case LitterBox.open_session(:local_code, [], profile: profile) do
      {:ok, session} ->
        try do
          {:ok, process} =
            LitterBox.start_process(session,
              runtime: :bash,
              source: "read line; printf \"process:%s\" \"$line\""
            )

          :ok = LitterBox.write_process_stdin(process, "vmsan-ok\n")
          :ok = LitterBox.close_process_stdin(process)
          {:ok, events} = LitterBox.process_events(process)
          output = events |> Enum.map_join("", &(get_in(&1.payload, [:chunk]) || ""))

          unless output =~ "process:vmsan-ok" do
            raise "vmsan process smoke did not observe expected output: #{inspect(output)}"
          end

          IO.puts("vmsan process smoke passed")
        after
          LitterBox.close_session(session)
        end

      {:error, error} ->
        IO.puts("vmsan process smoke skipped: session could not be opened")
        IO.inspect(error, label: "error")
    end

  {:ok, %{backends: [%{missing_requirements: missing, diagnostics: diagnostics}]}} ->
    IO.puts("vmsan process smoke skipped: provider unavailable")
    IO.inspect(missing, label: "missing_requirements")
    IO.inspect(diagnostics, label: "diagnostics")

  {:error, error} ->
    raise "vmsan process smoke failed before status: #{error.message}"
end
