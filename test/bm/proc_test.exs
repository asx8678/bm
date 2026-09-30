defmodule Bm.ProcTest do
  use ExUnit.Case, async: true

  alias Bm.Proc

  # Starts `sh -c script` through the launcher and returns the port and its os pid.
  defp launch(script) do
    {exe, args} = Proc.launch_args("/bin/sh", ["-c", script])
    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, args: args])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> Proc.terminate_groups([os_pid], 200) end)
    {port, os_pid}
  end

  test "the launched program leads its own process group" do
    {port, os_pid} = launch("ps -o pgid= -p $$")
    assert_receive {^port, {:data, out}}, 2_000
    assert String.trim(out) == Integer.to_string(os_pid)
  end

  test "background jobs stay in the group after the shell exits and a group kill ends them" do
    {port, pgid} = launch("nohup sleep 30 >/dev/null 2>&1 & (sleep 30 >/dev/null 2>&1 &); exit 0")
    assert_receive {^port, {:exit_status, 0}}, 2_000

    assert [_, _] = Proc.group_members([pgid])
    assert :ok = Proc.terminate_groups([pgid])
    assert Proc.group_members([pgid]) == []
  end

  test "a process that ignores TERM is killed" do
    {_port, pgid} = launch("trap '' TERM; while :; do sleep 0.05; done")
    assert [_ | _] = Proc.group_members([pgid])
    assert :ok = Proc.terminate_groups([pgid], 200)
  end

  test "empty and gone groups are fine" do
    assert Proc.terminate_groups([]) == :ok
    assert Proc.group_members([999_999_999]) == []
    assert Proc.terminate_groups([999_999_999]) == :ok
  end

  test "live_groups keeps only groups that still have processes" do
    {_port, pgid} = launch("sleep 30")
    assert Proc.live_groups([pgid, 999_999_999]) == [pgid]
    Proc.terminate_groups([pgid])
    assert Proc.live_groups([pgid]) == []
  end

  test "boot_id is stable within a boot" do
    assert is_binary(Proc.boot_id())
    assert Proc.boot_id() == Proc.boot_id()
  end

  @tag :tmp_dir
  test "read_pgid_file parses recorded group ids", %{tmp_dir: dir} do
    path = Path.join(dir, "pgids")
    assert Proc.read_pgid_file(path) == []

    File.write!(path, "123\n456\n123\n\ngarbage\n1\n")
    assert Proc.read_pgid_file(path) == [123, 456]
  end
end
