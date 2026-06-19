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
          {:ok, _result} =
            LitterBox.exec(session,
              runtime: :bash,
              source: "printf before > /workspace/checkpoint.txt"
            )

          {:ok, checkpoint} = LitterBox.checkpoint(session, id: "smoke")

          unless checkpoint.metadata.kind == :microvm_snapshot and
                   checkpoint.metadata.preserves.process_memory == true do
            raise "vmsan checkpoint metadata is not a microVM snapshot: #{inspect(checkpoint.metadata)}"
          end

          {:ok, restored} = LitterBox.restore(session, checkpoint)
          Process.put(:litter_box_vmsan_snapshot_smoke_session, restored)

          {:ok, result} =
            LitterBox.exec(restored,
              runtime: :bash,
              source: "cat /workspace/checkpoint.txt"
            )

          unless result.stdout =~ "before" do
            raise "vmsan snapshot smoke did not restore expected file: #{inspect(result.stdout)}"
          end

          IO.puts("vmsan snapshot smoke passed")
        after
          _ =
            LitterBox.close_session(
              Process.get(:litter_box_vmsan_snapshot_smoke_session, session)
            )
        end

      {:error, error} ->
        IO.puts("vmsan snapshot smoke skipped: session could not be opened")
        IO.inspect(error, label: "error")
    end

  {:ok, %{backends: [%{missing_requirements: missing, diagnostics: diagnostics}]}} ->
    IO.puts("vmsan snapshot smoke skipped: provider unavailable")
    IO.inspect(missing, label: "missing_requirements")
    IO.inspect(diagnostics, label: "diagnostics")

  {:error, error} ->
    raise "vmsan snapshot smoke failed before status: #{error.message}"
end
