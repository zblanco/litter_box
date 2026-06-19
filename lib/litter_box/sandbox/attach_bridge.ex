defmodule LitterBox.AttachBridge do
  @moduledoc """
  Consumer-neutral summary bridge for sandbox attach event streams.

  The bridge does not emit RunicAI, Ariston, or UI-specific events. It keeps the
  provider-neutral facts consumers need to map attach output into their own
  traces: ordered chunks, stdout/stderr text, terminal status, counts, and
  backend/session metadata.
  """

  alias LitterBox.AttachHandle
  alias LitterBox.SessionEvent

  @type chunk :: %{
          stream: :stdout | :stderr,
          chunk: binary(),
          bytes: non_neg_integer(),
          event_id: String.t(),
          at: DateTime.t(),
          metadata: map()
        }

  @type summary :: %{
          attach_id: String.t() | nil,
          session_id: String.t() | nil,
          backend: atom() | nil,
          status: :pass | :fail,
          exit_status: integer() | nil,
          stdout: binary(),
          stderr: binary(),
          combined: binary(),
          chunks: [chunk()],
          chunk_counts: %{stdout: non_neg_integer(), stderr: non_neg_integer()},
          byte_counts: %{
            stdout: non_neg_integer(),
            stderr: non_neg_integer(),
            combined: non_neg_integer()
          },
          event_count: non_neg_integer(),
          terminal_count: non_neg_integer(),
          effective_terminal: map(),
          last_terminal: map() | nil,
          missing_terminal?: boolean(),
          synthetic_terminal?: boolean(),
          metadata: map()
        }

  @spec summarize(AttachHandle.t() | Enumerable.t(), keyword()) :: summary()
  def summarize(events_or_handle, opts \\ [])

  def summarize(%AttachHandle{} = handle, opts) do
    handle.events
    |> do_summarize(
      opts
      |> Keyword.put_new(:attach_id, handle.id)
      |> Keyword.put_new(:session_id, handle.session_id)
      |> Keyword.put_new(:backend, handle.backend)
      |> Keyword.put_new(:metadata, handle.metadata)
    )
  end

  def summarize(events, opts), do: do_summarize(events, opts)

  defp do_summarize(events, opts) do
    initial = %{
      attach_id: Keyword.get(opts, :attach_id),
      session_id: Keyword.get(opts, :session_id),
      backend: Keyword.get(opts, :backend),
      stdout_chunks: [],
      stderr_chunks: [],
      combined_chunks: [],
      chunks: [],
      event_count: 0,
      terminal_count: 0,
      effective_terminal: nil,
      last_terminal: nil,
      metadata: Map.new(Keyword.get(opts, :metadata, %{}))
    }

    events
    |> Enum.reduce(initial, &accumulate_event/2)
    |> finalize()
  end

  defp accumulate_event(%SessionEvent{type: type} = event, acc)
       when type in [:stdout_chunk, :stderr_chunk] do
    chunk = normalize_chunk(event)

    acc
    |> Map.update!(:event_count, &(&1 + 1))
    |> Map.update!(:chunks, &(&1 ++ [chunk]))
    |> Map.update!(:combined_chunks, &(&1 ++ [chunk.chunk]))
    |> update_stream_chunks(chunk)
  end

  defp accumulate_event(%SessionEvent{type: :exec_finished} = event, acc) do
    terminal = terminal_summary(event)

    acc
    |> Map.update!(:event_count, &(&1 + 1))
    |> Map.update!(:terminal_count, &(&1 + 1))
    |> Map.update!(:effective_terminal, &choose_terminal(&1, terminal))
    |> Map.put(:last_terminal, terminal)
  end

  defp accumulate_event(nil, acc), do: acc

  defp accumulate_event(%SessionEvent{} = _event, acc) do
    Map.update!(acc, :event_count, &(&1 + 1))
  end

  defp update_stream_chunks(acc, %{stream: :stdout, chunk: chunk}) do
    Map.update!(acc, :stdout_chunks, &(&1 ++ [chunk]))
  end

  defp update_stream_chunks(acc, %{stream: :stderr, chunk: chunk}) do
    Map.update!(acc, :stderr_chunks, &(&1 ++ [chunk]))
  end

  defp choose_terminal(nil, terminal), do: terminal
  defp choose_terminal(%{status: :pass} = current, %{status: :pass}), do: current
  defp choose_terminal(_current, %{status: :fail} = terminal), do: terminal
  defp choose_terminal(%{status: :fail} = current, %{status: :pass}), do: current

  defp normalize_chunk(%SessionEvent{} = event) do
    stream =
      event.payload
      |> get(:stream, stream_from_type(event.type))
      |> normalize_stream(event.type)

    chunk =
      event.payload
      |> get(:chunk, "")
      |> IO.iodata_to_binary()

    %{
      stream: stream,
      chunk: chunk,
      bytes: byte_size(chunk),
      event_id: event.id,
      at: event.at,
      metadata: event.metadata
    }
  end

  defp terminal_summary(%SessionEvent{} = event) do
    exit_status = get(event.payload, :exit_status, nil)
    status = normalize_status(get(event.payload, :status, nil), exit_status)

    %{
      event_id: event.id,
      at: event.at,
      status: status,
      exit_status: exit_status,
      payload: event.payload,
      metadata: event.metadata,
      synthetic?: false
    }
  end

  defp finalize(acc) do
    stdout = Enum.join(acc.stdout_chunks, "")
    stderr = Enum.join(acc.stderr_chunks, "")
    combined = Enum.join(acc.combined_chunks, "")
    terminal = acc.effective_terminal || missing_terminal(acc)

    %{
      attach_id: acc.attach_id,
      session_id: acc.session_id,
      backend: acc.backend,
      status: terminal.status,
      exit_status: terminal.exit_status,
      stdout: stdout,
      stderr: stderr,
      combined: combined,
      chunks: acc.chunks,
      chunk_counts: %{stdout: length(acc.stdout_chunks), stderr: length(acc.stderr_chunks)},
      byte_counts: %{
        stdout: byte_size(stdout),
        stderr: byte_size(stderr),
        combined: byte_size(combined)
      },
      event_count: acc.event_count,
      terminal_count: acc.terminal_count,
      effective_terminal: terminal,
      last_terminal: acc.last_terminal,
      missing_terminal?: acc.effective_terminal == nil,
      synthetic_terminal?: terminal.synthetic?,
      metadata: acc.metadata
    }
  end

  defp missing_terminal(acc) do
    %{
      event_id: "synthetic-missing-terminal",
      at: DateTime.utc_now(),
      status: :fail,
      exit_status: nil,
      payload: %{
        status: :fail,
        reason: :missing_exec_finished,
        message: "sandbox attach stream ended without exec_finished"
      },
      metadata: %{
        attach_id: acc.attach_id,
        session_id: acc.session_id,
        backend: acc.backend
      },
      synthetic?: true
    }
  end

  defp normalize_status(status, _exit_status) when status in [:pass, :fail], do: status
  defp normalize_status("pass", _exit_status), do: :pass
  defp normalize_status("fail", _exit_status), do: :fail
  defp normalize_status(nil, 0), do: :pass
  defp normalize_status(nil, exit_status) when is_integer(exit_status), do: :fail
  defp normalize_status(_status, _exit_status), do: :fail

  defp normalize_stream(stream, _type) when stream in [:stdout, :stderr], do: stream
  defp normalize_stream("stdout", _type), do: :stdout
  defp normalize_stream("stderr", _type), do: :stderr
  defp normalize_stream(_stream, type), do: stream_from_type(type)

  defp stream_from_type(:stderr_chunk), do: :stderr
  defp stream_from_type(_type), do: :stdout

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
