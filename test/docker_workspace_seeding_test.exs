defmodule LitterBox.Backends.DockerWorkspaceSeedingTest do
  use ExUnit.Case, async: false

  alias LitterBox.Backends.Docker
  alias LitterBox.Profile
  alias LitterBox.Test.FakeDocker

  import Bitwise, only: [band: 2]

  @image "runic-ai/sandbox:elixir-python-node"

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "litter_box_docker_workspace_seed_#{System.unique_integer([:positive])}"
      )

    File.rm_rf(tmp_root)
    File.mkdir_p!(tmp_root)

    on_exit(fn -> File.rm_rf(tmp_root) end)

    {:ok, tmp_root: tmp_root}
  end

  test "open_session seeds stateful workspace from host_root", %{tmp_root: tmp_root} do
    host_root = Path.join(tmp_root, "host-root")
    File.mkdir_p!(Path.join(host_root, "nested"))
    File.write!(Path.join(host_root, "README.md"), "seeded root\n")
    File.write!(Path.join(host_root, ".env.example"), "PUBLIC_VALUE=yes\n")
    File.write!(Path.join(host_root, "nested/file.txt"), "seeded nested\n")

    FakeDocker.with_fake_docker(tmp_root, fn docker_log ->
      profile =
        docker_profile(workspace: [mode: :stateful, persist?: true, host_root: host_root])

      assert {:ok, session} = Docker.open_session(profile, [])

      try do
        workspace_root = session.metadata.workspace_root

        assert File.read!(Path.join(workspace_root, "README.md")) == "seeded root\n"
        assert File.read!(Path.join(workspace_root, ".env.example")) == "PUBLIC_VALUE=yes\n"
        assert File.read!(Path.join(workspace_root, "nested/file.txt")) == "seeded nested\n"
        assert writable_by_unmapped_user?(Path.join(workspace_root, "README.md"))
        assert writable_by_unmapped_user?(Path.join(workspace_root, "nested"))
        assert File.read!(docker_log) =~ "run -d"
      after
        Docker.close_session(session, [])
      end
    end)
  end

  test "open_session leaves host_root nil stateful workspace empty", %{tmp_root: tmp_root} do
    FakeDocker.with_fake_docker(tmp_root, fn _docker_log ->
      profile = docker_profile(workspace: [mode: :stateful, persist?: true])

      assert {:ok, session} = Docker.open_session(profile, [])

      try do
        assert File.ls!(session.metadata.workspace_root) == []
      after
        Docker.close_session(session, [])
      end
    end)
  end

  test "open_session fails closed when host_root does not exist", %{tmp_root: tmp_root} do
    missing_host_root = Path.join(tmp_root, "missing-host-root")

    FakeDocker.with_fake_docker(tmp_root, fn docker_log ->
      profile =
        docker_profile(workspace: [mode: :stateful, persist?: true, host_root: missing_host_root])

      assert {:error, error} = Docker.open_session(profile, [])
      assert error.message == "docker workspace host_root must be an existing directory"
      assert error.details.host_root == Path.expand(missing_host_root)
      assert error.details.reason == :enoent
      refute File.read!(docker_log) =~ "run -d"
    end)
  end

  test "open_session fails closed when host_root is not a directory", %{tmp_root: tmp_root} do
    file_host_root = Path.join(tmp_root, "host-root-file")
    File.write!(file_host_root, "not a directory")

    FakeDocker.with_fake_docker(tmp_root, fn docker_log ->
      profile =
        docker_profile(workspace: [mode: :stateful, persist?: true, host_root: file_host_root])

      assert {:error, error} = Docker.open_session(profile, [])
      assert error.message == "docker workspace host_root must be an existing directory"
      assert error.details.host_root == Path.expand(file_host_root)
      assert error.details.type == :regular
      refute File.read!(docker_log) =~ "run -d"
    end)
  end

  defp docker_profile(opts) do
    Profile.new!(
      name: :local_code,
      backend: :docker,
      runtimes: [:bash],
      network: :disabled,
      image: @image,
      workspace: Keyword.fetch!(opts, :workspace)
    )
  end

  defp writable_by_unmapped_user?(path) do
    %{mode: mode} = File.stat!(path)
    band(mode, 0o002) == 0o002
  end
end
