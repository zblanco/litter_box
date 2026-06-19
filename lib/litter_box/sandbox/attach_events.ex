defmodule LitterBox.AttachEvents do
  @moduledoc false

  alias LitterBox.AttachHandle
  alias LitterBox.ExecutionRequest
  alias LitterBox.ExecutionResult
  alias LitterBox.Session
  alias LitterBox.SessionEvent

  @spec terminal_handle(Session.t(), ExecutionRequest.t(), ExecutionResult.t(), keyword()) ::
          {:ok, AttachHandle.t()}
  def terminal_handle(
        %Session{} = session,
        %ExecutionRequest{} = request,
        %ExecutionResult{} = result,
        opts \\ []
      ) do
    events = terminal_events(session, request, result)

    AttachHandle.new(
      id: Keyword.get(opts, :id, attach_id()),
      session_id: session.id,
      backend: session.backend,
      status: :closed,
      events: events,
      metadata:
        Map.merge(
          %{
            streaming_live?: false,
            terminal_result?: true,
            status: result.status,
            exit_status: result.exit_status
          },
          Map.new(Keyword.get(opts, :metadata, %{}))
        )
    )
  end

  @spec terminal_events(Session.t(), ExecutionRequest.t(), ExecutionResult.t()) :: [
          SessionEvent.t()
        ]
  def terminal_events(
        %Session{} = session,
        %ExecutionRequest{} = request,
        %ExecutionResult{} = result
      ) do
    [
      event(session, :exec_started, %{
        runtime: request.runtime,
        mode: request.mode,
        argv: request.argv,
        cwd: request.cwd,
        network: request.network,
        streaming_live?: false
      }),
      chunk_event(session, :stdout_chunk, result.stdout),
      chunk_event(session, :stderr_chunk, result.stderr),
      event(session, :exec_finished, %{
        status: result.status,
        exit_status: result.exit_status,
        duration_ms: result.duration_ms,
        files_changed: result.files_changed,
        artifacts: result.artifacts,
        diagnostics: result.diagnostics,
        resource_usage: result.resource_usage,
        metadata: result.metadata,
        streaming_live?: false
      })
    ]
    |> Enum.reject(&is_nil/1)
  end

  @spec event(Session.t(), atom(), map()) :: SessionEvent.t()
  def event(%Session{} = session, type, payload) when is_map(payload) do
    SessionEvent.new!(
      id: event_id(type),
      session_id: session.id,
      type: type,
      payload: payload,
      metadata: %{
        sandbox: session.sandbox,
        backend: session.backend,
        isolation_level: session.isolation_level
      }
    )
  end

  @spec chunk_event(Session.t(), :stdout_chunk | :stderr_chunk, binary()) ::
          SessionEvent.t() | nil
  def chunk_event(_session, _type, ""), do: nil

  def chunk_event(%Session{} = session, type, chunk)
      when type in [:stdout_chunk, :stderr_chunk] do
    stream =
      case type do
        :stdout_chunk -> :stdout
        :stderr_chunk -> :stderr
      end

    event(session, type, %{stream: stream, chunk: chunk})
  end

  @spec attach_id() :: String.t()
  def attach_id, do: "attach-#{System.unique_integer([:positive])}"

  defp event_id(type), do: "#{type}-#{System.unique_integer([:positive])}"
end
