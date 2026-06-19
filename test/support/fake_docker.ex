defmodule LitterBox.Test.FakeDocker do
  @moduledoc false

  def with_fake_docker(fun) when is_function(fun, 1) do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "fake_docker_#{System.unique_integer([:positive])}"
      )

    File.rm_rf(tmp_root)
    File.mkdir_p!(tmp_root)

    try do
      with_fake_docker(tmp_root, fun)
    after
      File.rm_rf(tmp_root)
    end
  end

  def with_fake_docker(tmp_root, fun) when is_function(fun, 1) do
    fake_bin = Path.join(tmp_root, "fake-bin")
    docker_log = Path.join(tmp_root, "docker.log")
    docker_path = Path.join(fake_bin, "docker")

    File.mkdir_p!(fake_bin)

    File.write!(docker_path, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "#{docker_log}"

    case "$1 $2" in
      "info --format")
        if [ "$3" = "{{json .Runtimes}}" ]; then
          printf '{"runc":{}}\\n'
        else
          printf '25.0.0\\n'
        fi
        exit 0
        ;;
      "image inspect")
        exit 0
        ;;
      "run -d")
        printf 'fake-container-id\\n'
        exit 0
        ;;
      "rm -f")
        exit 0
        ;;
      *)
        printf 'unexpected docker args: %s\\n' "$*" >&2
        exit 1
        ;;
    esac
    """)

    File.chmod!(docker_path, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", fake_bin <> ":" <> (old_path || ""))

    try do
      fun.(docker_log)
    after
      restore_path(old_path)
    end
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end
