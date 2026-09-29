defmodule Bm.Proc do
  @moduledoc """
  OS process groups for everything a BM agent starts (docs/ARCHITECTURE.md, decision D18).

  pi is started through `launch_args/2`, which makes it the leader of a new session and process
  group, so its pid is also its group id. pi's bash tool runs every command in a session of its
  own; `bm_guard` records each command's group id in the file named by `BM_PGID_FILE`
  (`read_pgid_file/1`). Background jobs keep their group id even after they are re-parented to
  PID 1, so these group ids find everything a worker left running. Only a process that starts a
  new session itself escapes; this is a safety net, not a sandbox.

  **Reused ids.** Once a group is empty its id can be reused by an unrelated program. Callers
  therefore stop tracking a group the first time `live_groups/1` finds it empty (see
  `Bm.Pi.process_groups/1`), and recovery ignores groups recorded before the last boot
  (`boot_id/0`).
  """

  @poll_interval 50

  @doc "Path of the launcher script (`setsid` + `exec`)."
  def launcher, do: Application.app_dir(:bm, "priv/pi/setsid.pl")

  @doc """
  Executable and arguments that run `path args...` as a new session and group leader, for
  `Port.open({:spawn_executable, executable}, args: args)`.
  """
  def launch_args(path, args) do
    perl = System.find_executable("perl") || raise "perl not found; it is needed to start pi"
    {perl, [launcher(), path | args]}
  end

  @doc "Pids of the live processes in the given process groups."
  def group_members(pgids) do
    wanted = MapSet.new(pgids)

    case System.cmd("ps", ["-A", "-o", "pid=,pgid="], stderr_to_stdout: true) do
      {out, 0} ->
        for line <- String.split(out, "\n", trim: true),
            [pid, pgid] <- [line |> String.split() |> Enum.map(&String.to_integer/1)],
            MapSet.member?(wanted, pgid),
            do: pid

      {out, status} ->
        raise "ps failed with status #{status}: #{out}"
    end
  end

  @doc "The groups among `pgids` that still have at least one process."
  def live_groups(pgids) do
    wanted = MapSet.new(pgids)

    case System.cmd("ps", ["-A", "-o", "pgid="], stderr_to_stdout: true) do
      {out, 0} ->
        live =
          for line <- String.split(out, "\n", trim: true),
              pgid <- [String.to_integer(String.trim(line))],
              MapSet.member?(wanted, pgid),
              into: MapSet.new(),
              do: pgid

        Enum.filter(pgids, &MapSet.member?(live, &1))

      {out, status} ->
        raise "ps failed with status #{status}: #{out}"
    end
  end

  @doc """
  Identifies the current boot. Group ids recorded before a reboot mean nothing afterwards (every
  pid may belong to another program now), so recovery only signals groups from the same boot.
  """
  def boot_id do
    case File.read("/proc/sys/kernel/random/boot_id") do
      {:ok, id} ->
        String.trim(id)

      {:error, _} ->
        # macOS: "{ sec = 1790091645, usec = 528289 } Tue Sep 22 17:40:45 2026"
        {out, 0} = System.cmd("sysctl", ["-n", "kern.boottime"])
        [_, sec, usec] = Regex.run(~r/sec = (\d+), usec = (\d+)/, out)
        "#{sec}.#{usec}"
    end
  end

  @doc "Sends `signal` (e.g. `\"TERM\"`) to every process in the groups. Gone groups are skipped."
  def signal_groups(pgids, signal) do
    for pgid <- pgids, pgid > 1 do
      System.cmd("kill", ["-#{signal}", "--", "-#{pgid}"], stderr_to_stdout: true)
    end

    :ok
  end

  @doc "Waits until no process is left in the groups. Returns `:ok` or `{:error, pids}`."
  def await_groups_empty(pgids, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(pgids, deadline)
  end

  defp do_await(pgids, deadline) do
    case group_members(pgids) do
      [] ->
        :ok

      pids ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, pids}
        else
          Process.sleep(@poll_interval)
          do_await(pgids, deadline)
        end
    end
  end

  @doc """
  Ends every process in the groups: TERM, then KILL for whatever is left after `grace` ms.
  Returns `:ok` or `{:error, pids}` for processes that survived both.
  """
  def terminate_groups(pgids, grace \\ 1_000)
  def terminate_groups([], _grace), do: :ok

  def terminate_groups(pgids, grace) do
    if group_members(pgids) == [] do
      :ok
    else
      signal_groups(pgids, "TERM")

      with {:error, _} <- await_groups_empty(pgids, grace) do
        signal_groups(pgids, "KILL")
        await_groups_empty(pgids, grace)
      end
    end
  end

  @doc "Group ids recorded in a `BM_PGID_FILE` (one per line). A missing file has none."
  def read_pgid_file(path) do
    case File.read(path) do
      {:ok, content} ->
        for line <- String.split(content, "\n", trim: true),
            {pgid, ""} <- [Integer.parse(String.trim(line))],
            pgid > 1,
            uniq: true,
            do: pgid

      {:error, _} ->
        []
    end
  end
end
