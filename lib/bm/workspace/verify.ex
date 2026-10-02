defmodule Bm.Workspace.Verify do
  @moduledoc """
  Runs a workspace's verify command (docs/ARCHITECTURE.md §7) as the leader of its own process
  group, so a timeout or a cancel ends everything it started. Keeps the last 4 KB of output,
  as valid UTF-8 (it is stored as JSON).
  """

  @output_tail 4_096

  # The command runs in an inner shell with no input (a prompt fails at once instead of waiting
  # for the timeout); the outer shell then prints its exit status as a marker. The marker, not
  # the port's exit status, ends the wait: a port reports its exit only once every process
  # holding its output has closed it, and a background child (a server, `sleep &`) turned a pass
  # into a timeout (plan 36.10). `exec` inside the command replaces only the inner shell.
  @wrapper ~S[/bin/sh -c "$1" </dev/null; printf '\n\036bm-exit %d\n' "$?"]
  @marker ~r/\n?\x{1E}bm-exit (\d+)\n/u

  @doc """
  Runs `command` with `sh -c` in `root`. Sends `{:verify_started, pgid}` to `notify` once it
  runs. Returns `%{"exit" => status, "output" => tail}`, or with `"exit" => nil` and
  `"timeout" => true` after `timeout` ms. The whole group is ended afterwards either way.
  """
  def run(command, root, timeout, notify) do
    {exe, args} = Bm.Proc.launch_args("/bin/sh", ["-c", @wrapper, "bm-verify", command])

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
      {^port, {:data, data}} ->
        output = output <> data

        case Regex.run(@marker, output, return: :index) do
          [{at, _}, {code_at, code_len}] ->
            status = output |> binary_part(code_at, code_len) |> String.to_integer()
            close(port)
            %{"exit" => status, "output" => printable(tail(binary_part(output, 0, at)))}

          nil ->
            collect_output(port, tail(output), deadline)
        end

      # The wrapper itself died (killed): no marker.
      {^port, {:exit_status, status}} ->
        %{"exit" => status, "output" => printable(output)}
    after
      remaining ->
        close(port)
        %{"exit" => nil, "timeout" => true, "output" => printable(output)}
    end
  end

  defp close(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  # Invalid UTF-8 (binary output, or a character cut by `tail/1`) is replaced.
  defp printable(output), do: String.replace_invalid(output)

  defp tail(output) when byte_size(output) <= @output_tail, do: output

  defp tail(output),
    do: binary_part(output, byte_size(output) - @output_tail, @output_tail)
end
