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

  @doc """
  Like `System.cmd/3`, with a `:timeout` (ms, default 120 s): a command still running then is
  killed (TERM, then KILL) and `{output, :timeout}` returned. For git and other tools BM calls
  inside its GenServers, where a hung command (a clean filter, gpg's pinentry, a network
  filesystem) would wedge the caller (plan 36.10). Options: `:cd`, `:env`, `:stderr_to_stdout`.
  """
  def cmd(command, args, opts \\ []) do
    exe = System.find_executable(command) || raise ArgumentError, "#{command} not found"
    timeout = Keyword.get(opts, :timeout, 120_000)

    port_opts =
      [:binary, :exit_status, :hide, args: args] ++
        if(opts[:stderr_to_stdout], do: [:stderr_to_stdout], else: []) ++
        if(opts[:cd], do: [cd: opts[:cd]], else: []) ++
        if(opts[:env],
          do: [env: Enum.map(opts[:env], fn {k, v} -> {to_charlist(k), env_value(v)} end)],
          else: []
        )

    port = Port.open({:spawn_executable, exe}, port_opts)
    {:os_pid, pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, pid, [], deadline)
  end

  # nil unsets the variable, as with System.cmd.
  defp env_value(nil), do: false
  defp env_value(value), do: to_charlist(value)

  defp collect(port, pid, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, pid, [acc | data], deadline)
      {^port, {:exit_status, status}} -> {IO.iodata_to_binary(acc), status}
    after
      remaining ->
        System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
        Process.sleep(200)
        System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

        try do
          Port.close(port)
        catch
          :error, :badarg -> :ok
        end

        {IO.iodata_to_binary(acc), :timeout}
    end
  end

  @doc "Group ids recorded in a `BM_PGID_FILE` (one per line). A missing file has none."
  def read_pgid_file(path),
    do: path |> read_pgid_records() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  @doc """
  The records of a `BM_PGID_FILE`: `{pgid, recorded_at}` (Unix seconds; nil in lines written
  before the time was recorded).
  """
  def read_pgid_records(path) do
    case path && File.read(path) do
      {:ok, content} ->
        for line <- String.split(content, "\n", trim: true),
            [pgid | rest] <- [String.split(line)],
            {pgid, ""} <- [Integer.parse(pgid)],
            pgid > 1,
            do: {pgid, recorded_at(rest)}

      _ ->
        []
    end
  end

  defp recorded_at([at | _]) do
    case Integer.parse(at) do
      {at, ""} -> at
      _ -> nil
    end
  end

  defp recorded_at([]), do: nil

  @doc """
  The group ids among `records` (`{pgid, recorded_at}`) not taken over by another program since
  they were recorded (plan 36.10). Pids wrap (about daily on a busy Mac): a group that emptied can
  get its id back as an unrelated program's. A group id can't be reused while the group has
  members, so an id is reused only if a live process with that pid (the new leader) started after
  the id was recorded. A gone leader with members left means the members are still the
  recorded group's.
  """
  def not_reused(records) do
    started = start_times(Enum.map(records, &elem(&1, 0)))

    for {pgid, at} <- records, pgid > 1, not reused?(started[pgid], at), uniq: true, do: pgid
  end

  # A second of slack: `date` and the shell's start fall in the same second or one apart.
  defp reused?(nil, _at), do: false
  defp reused?(_started, nil), do: false
  defp reused?(started, at), do: started > at + 1

  @doc "Unix start time (seconds) of each live pid among `pids`."
  def start_times([]), do: %{}

  def start_times(pids) do
    {out, _status} =
      System.cmd("ps", ["-o", "pid=,etime=", "-p", Enum.join(Enum.uniq(pids), ",")],
        stderr_to_stdout: true
      )

    now = System.os_time(:second)

    for line <- String.split(out, "\n", trim: true),
        [pid, etime] <- [String.split(line)],
        {pid, ""} <- [Integer.parse(pid)],
        seconds when is_integer(seconds) <- [elapsed(etime)],
        into: %{},
        do: {pid, now - seconds}
  end

  # `ps` etime: [[dd-]hh:]mm:ss
  defp elapsed(etime) do
    {days, rest} =
      case String.split(etime, "-") do
        [d, rest] -> {String.to_integer(d), rest}
        [rest] -> {0, rest}
      end

    parts = rest |> String.split(":") |> Enum.map(&String.to_integer/1)
    [s, m, h] = Enum.reverse(parts) ++ List.duplicate(0, 3 - length(parts))
    days * 86_400 + h * 3_600 + m * 60 + s
  rescue
    _ -> nil
  end
end
