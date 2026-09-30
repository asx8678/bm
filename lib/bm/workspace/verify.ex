defmodule Bm.Workspace.Verify do
  @moduledoc """
  Runs a workspace's verify command (docs/ARCHITECTURE.md §7) as the leader of its own process
  group, so a timeout or a cancel ends everything it started. Keeps the last 4 KB of output,
  as valid UTF-8 (it is stored as JSON).
  """

  @output_tail 4_096

  @doc """
  Runs `command` with `sh -c` in `root`. Sends `{:verify_started, pgid}` to `notify` once it
  runs. Returns `%{"exit" => status, "output" => tail}`, or with `"exit" => nil` and
  `"timeout" => true` after `timeout` ms. The whole group is ended afterwards either way.
  """
  def run(command, root, timeout, notify) do
    {exe, args} = Bm.Proc.launch_args("/bin/sh", ["-c", command])

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        cd: root
      ])

    {:os_pid, pgid} = Port.info(port, :os_pid)
    send(notify, {:verify_started, pgid})
    deadline = System.monotonic_time(:millisecond) + timeout
    result = collect_output(port, "", deadline)
    Bm.Proc.terminate_groups([pgid], 500)
    result
  end

  defp collect_output(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect_output(port, tail(output <> data), deadline)
      {^port, {:exit_status, status}} -> %{"exit" => status, "output" => printable(output)}
    after
      remaining ->
        Port.close(port)
        %{"exit" => nil, "timeout" => true, "output" => printable(output)}
    end
  end

  # Invalid UTF-8 (binary output, or a character cut by `tail/1`) is replaced.
  defp printable(output), do: String.replace_invalid(output)

  defp tail(output) when byte_size(output) <= @output_tail, do: output

  defp tail(output),
    do: binary_part(output, byte_size(output) - @output_tail, @output_tail)
end
