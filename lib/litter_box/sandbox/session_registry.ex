defmodule LitterBox.SessionRegistry do
  @moduledoc false

  use GenServer

  @name __MODULE__

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: @name)

  def start(_opts \\ []), do: GenServer.start(__MODULE__, %{}, name: @name)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register, session_id, snapshot, signature}, _from, state) do
    {:reply, :ok, Map.put(state, session_id, %{snapshot: snapshot, signature: signature})}
  end

  def handle_call({:verify, session_id, snapshot, signature}, _from, state) do
    result =
      case Map.fetch(state, session_id) do
        {:ok, %{snapshot: ^snapshot, signature: ^signature}} -> :ok
        {:ok, _record} -> {:error, :mismatch}
        :error -> {:error, :unknown}
      end

    {:reply, result, state}
  end

  def handle_call({:revoke, session_id}, _from, state) do
    {:reply, :ok, Map.delete(state, session_id)}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}
end
