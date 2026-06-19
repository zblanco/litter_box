defmodule LitterBox.Test.NoAttachBackend do
  @moduledoc false

  @behaviour LitterBox.Backend

  alias LitterBox.ExecutionRequest
  alias LitterBox.ExecutionResult
  alias LitterBox.Instance
  alias LitterBox.Profile

  @impl true
  def provision(%Profile{} = profile, _opts), do: {:ok, Instance.from_profile(profile)}

  @impl true
  def exec(%Instance{} = instance, %ExecutionRequest{}, _opts) do
    ExecutionResult.new(
      status: :pass,
      stdout: "no-attach\n",
      stderr: "",
      exit_status: 0,
      duration_ms: 1,
      backend: instance.backend,
      isolation_level: instance.isolation_level
    )
  end

  @impl true
  def upload(%Instance{}, _files, _opts), do: {:ok, []}

  @impl true
  def download(%Instance{}, _paths, _opts), do: {:ok, []}

  @impl true
  def snapshot(%Instance{} = instance, _opts), do: {:ok, %{instance_id: instance.id}}

  @impl true
  def reset(%Instance{}, _opts), do: :ok

  @impl true
  def destroy(%Instance{}, _opts), do: :ok

  @impl true
  def health(_opts), do: {:ok, %{available?: true}}
end
