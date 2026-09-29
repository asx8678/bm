defmodule Bm.Policy do
  @moduledoc """
  Decides whether a worker's mutating tool call may run. `bm_guard` asks before every `edit`,
  `write` and `bash` call (as a `bm:authorize` dialog) and the workspace coordinator answers with
  `authorize/3`.

  - `edit` / `write`: the path must resolve inside the workspace (after pi's own path rules and
    symlinks), outside `.git`, and must not be a **user-owned** file (the run's baseline). Writes
    outside the task's declared set are allowed here and flagged afterwards from the snapshot
    write set.
  - `bash`: refuses git commands that change the repository or the user's index, `setsid` (it
    would escape BM's process-group tracking, decision D18), `sudo`, recursive `rm` outside the
    workspace, and publishing commands.

  **Read-only mode** (`ctx.mode == :read_only`, for the planner and read-only workers, plan
  step 6.6.5): `edit` and `write` are refused outright, and so is every bash command that names a
  file to write (redirections other than devices or temp files, `tee`, `sed -i`, `cp`, `mv`,
  `rm`, `mkdir`, `touch`, `chmod` …) and every git write. The snapshot after the session still
  decides: a read-only session that changed files fails.

  **This is a safety net, not a sandbox.** Shell parsing here is approximate: variables, `eval`,
  scripts and interpreters can do anything a permitted command can. Snapshots attribute every
  change afterwards (decision D11), whatever made it.
  """

  @type ctx :: %{
          required(:root) => Path.t(),
          required(:user_owned) => [String.t()],
          optional(:mode) => :write | :read_only
        }
  @type decision :: :allow | {:deny, String.t()}

  # git subcommands that change the repository, the index or the working tree.
  @git_writes ~w(add am apply checkout cherry-pick clean commit gc merge mv notes pull push
                 rebase reset restore revert rm switch update-index update-ref worktree)
  # Global git options that take a separate value (`git -C dir status`).
  @git_options_with_value ~w(-C -c --git-dir --work-tree --namespace --exec-path)

  @publishing [
    ~w(npm publish),
    ~w(yarn publish),
    ~w(pnpm publish),
    ~w(mix hex.publish),
    ~w(cargo publish),
    ~w(gem push),
    ~w(twine upload),
    ~w(docker push),
    ~w(gh release),
    ~w(gh pr)
  ]

  @doc "Decides a tool call. `input` is the tool's arguments as sent by pi."
  @spec authorize(String.t(), map(), ctx) :: decision
  def authorize(tool, _input, %{mode: :read_only}) when tool in ["edit", "write"] do
    {:deny, "This task is read-only: report what you found instead of changing files."}
  end

  def authorize(tool, input, ctx) when tool in ["edit", "write"] do
    case input do
      %{"path" => path} when is_binary(path) -> authorize_path(path, ctx)
      _ -> {:deny, "#{tool} needs a path."}
    end
  end

  def authorize("bash", %{"command" => command}, ctx) when is_binary(command) do
    checks =
      Enum.map(redirect_targets(command), &{:write_target, &1}) ++
        Enum.map(segments(command), &{:segment, &1})

    Enum.find_value(checks, :allow, fn
      {:write_target, target} -> denied(check_write_target(target, ctx))
      {:segment, tokens} -> denied(check_segment(tokens, ctx))
    end)
  end

  def authorize("bash", _input, _ctx), do: {:deny, "bash needs a command."}
  def authorize(tool, _input, _ctx), do: {:deny, "BM does not allow the #{tool} tool here."}

  defp denied(:allow), do: nil
  defp denied(deny), do: deny

  ## Paths

  defp authorize_path(path, ctx) do
    root = real_path(ctx.root)
    full = path |> pi_path() |> Path.expand(root) |> real_path()

    cond do
      not inside?(full, root) ->
        {:deny, "#{path} is outside the workspace. Only change files inside #{ctx.root}."}

      inside?(full, Path.join(root, ".git")) ->
        {:deny, "BM manages git itself; don't change files in .git."}

      Path.relative_to(full, root) in ctx.user_owned ->
        {:deny,
         "#{Path.relative_to(full, root)} has uncommitted changes of the user; BM must not " <>
           "change it. Report that the task needs it instead."}

      true ->
        :allow
    end
  end

  # pi's own rules (path-utils.js): strip a leading "@", expand "~", normalize odd spaces.
  defp pi_path(path) do
    path
    |> String.replace(~r/[\x{00A0}\x{2000}-\x{200A}\x{202F}\x{205F}\x{3000}]/u, " ")
    |> String.replace_prefix("@", "")
    |> case do
      "~" -> System.user_home!()
      "~/" <> rest -> Path.join(System.user_home!(), rest)
      other -> other
    end
  end

  # Resolves symlinks in every existing component; the missing tail is kept as is.
  defp real_path(path) do
    path = Path.expand(path)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, target} = File.read_link(path)
        target |> Path.expand(Path.dirname(path)) |> real_path()

      {:ok, %File.Stat{type: :directory}} ->
        {out, 0} = System.cmd("pwd", ["-P"], cd: path)
        String.trim(out)

      _file_or_missing ->
        parent = Path.dirname(path)
        if parent == path, do: path, else: Path.join(real_path(parent), Path.basename(path))
    end
  end

  defp inside?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  ## Shell commands

  # Splits a command into simple commands at ; & && || | and newlines, then into words. Quotes
  # are removed; this is deliberately rough (see the moduledoc).
  defp segments(command) do
    command
    |> String.split(~r/;|&&|\|\||\||&|\n|\$\(|`|\(|\)/)
    |> Enum.map(&words/1)
    |> Enum.reject(&(&1 == []))
  end

  defp words(segment) do
    ~r/"([^"]*)"|'([^']*)'|(\S+)/
    |> Regex.scan(segment, capture: :all_but_first)
    |> Enum.map(fn groups -> Enum.find(groups, "", &(&1 != "")) end)
  end

  defp check_segment(tokens, ctx) do
    # `env X=1 cmd`, `VAR=1 cmd`, `command cmd`, `exec cmd`, `time cmd`: look at the real command.
    case Enum.drop_while(tokens, &prefix_word?/1) do
      [] -> :allow
      [cmd | args] -> check_command(Path.basename(cmd), args, ctx)
    end
  end

  defp prefix_word?(word),
    do: word in ~w(env command exec time nice nohup builtin) or word =~ ~r/^[A-Za-z_]\w*=/

  defp check_command("git", args, _ctx), do: check_git(args)

  @write_commands ~w(tee mv cp install ln rm rmdir mkdir touch chmod chown chgrp truncate dd
                     patch rsync unzip tar)

  defp check_command(cmd, args, %{mode: :read_only}) when cmd in @write_commands do
    if cmd == "tar" and not Enum.any?(args, &String.contains?(&1, "x")),
      do: :allow,
      else: {:deny, "This task is read-only; #{cmd} would change files. Only inspect and run."}
  end

  defp check_command("sed", args, %{mode: :read_only}) do
    if in_place?(args),
      do: {:deny, "This task is read-only; sed -i would change files."},
      else: :allow
  end

  defp check_command(cmd, _args, _ctx) when cmd in ~w(setsid disown) do
    {:deny, "#{cmd} would detach processes from BM's tracking. Run the command normally."}
  end

  defp check_command(cmd, _args, _ctx) when cmd in ~w(sudo su doas) do
    {:deny, "#{cmd} is not allowed. Work without elevated privileges."}
  end

  # Deleting is fine inside the workspace and in temp directories, nowhere else.
  # Deleting is fine inside the workspace (except the user's files) and in temp directories.
  defp check_command("rm", args, ctx), do: check_write_targets(operands(args), ctx)

  # Commands that write the files named in their arguments.
  defp check_command("tee", args, ctx), do: check_write_targets(operands(args), ctx)

  defp check_command("sed", args, ctx) do
    if in_place?(args) do
      # Without -e the first operand is the script; the rest are the files it rewrites.
      files =
        if Enum.any?(args, &(&1 in ["-e", "--expression"])),
          do: operands(args),
          else: Enum.drop(operands(args), 1)

      check_write_targets(files, ctx)
    else
      :allow
    end
  end

  # mv removes its sources and writes its destination.
  defp check_command("mv", args, ctx), do: check_write_targets(operands(args), ctx)

  # The destination is the last operand.
  defp check_command(cmd, args, ctx) when cmd in ~w(cp install ln) do
    case operands(args) do
      [_ | _] = operands -> check_write_targets([List.last(operands)], ctx)
      [] -> :allow
    end
  end

  defp check_command(cmd, args, _ctx) do
    if [cmd | Enum.take(args, 1)] in @publishing,
      do: {:deny, "Publishing (#{Enum.join([cmd | Enum.take(args, 1)], " ")}) is not allowed."},
      else: :allow
  end

  defp in_place?(args) do
    Enum.any?(
      args,
      &(&1 in ["-i", "--in-place"] or String.starts_with?(&1, ["-i", "--in-place="]))
    )
  end

  defp check_git(args) do
    case git_subcommand(args) do
      {sub, rest} ->
        if git_write?(sub, rest),
          do:
            {:deny,
             "git #{sub} changes the repository. BM records and checkpoints changes itself; " <>
               "leave git to BM and only edit files."},
          else: :allow

      nil ->
        :allow
    end
  end

  defp git_subcommand([opt, _value | rest]) when opt in @git_options_with_value,
    do: git_subcommand(rest)

  defp git_subcommand(["-" <> _ | rest]), do: git_subcommand(rest)
  defp git_subcommand([sub | rest]), do: {sub, rest}
  defp git_subcommand([]), do: nil

  defp git_write?(sub, _rest) when sub in @git_writes, do: true

  # Listing branches is fine; naming one (create) or -d/-D/-m/-M/-c/-C/-f is not.
  defp git_write?("branch", rest) do
    Enum.any?(rest, fn arg ->
      not String.starts_with?(arg, "-") or arg in ~w(-d -D -m -M -c -C -f) or
        String.starts_with?(arg, ["--delete", "--move", "--copy", "--force", "--set-upstream"])
    end)
  end

  defp git_write?("tag", rest), do: not (rest == [] or hd(rest) in ["-l", "--list"])
  defp git_write?("stash", rest), do: not match?([sub | _] when sub in ~w(list show), rest)
  defp git_write?(_sub, _rest), do: false

  defp operands(args), do: Enum.reject(args, &String.starts_with?(&1, "-"))

  defp check_write_targets(targets, ctx) do
    Enum.find_value(targets, :allow, &denied(check_write_target(&1, ctx)))
  end

  # A file a shell command writes or deletes: temp files and devices are fine; everything else
  # follows the rules for edit/write.
  defp check_write_target(target, ctx) do
    cond do
      target in ~w(/dev/null /dev/stdout /dev/stderr /dev/tty) ->
        :allow

      String.starts_with?(target, "$") ->
        {:deny, "Writing to #{target} (a variable) is not allowed; name the file."}

      temporary?(target) ->
        :allow

      ctx[:mode] == :read_only ->
        {:deny, "This task is read-only; writing to #{target} is not allowed."}

      true ->
        authorize_path(target, ctx)
    end
  end

  # Targets of output redirections anywhere in the command: `> f`, `>> f`, `&> f`, `2> f`,
  # `>| f`. Duplications like `2>&1` are not files.
  defp redirect_targets(command) do
    ~r/(?:^|[^<>&\d])(?:\d|&)?>>?\|?\s*("[^"]+"|'[^']+'|[^\s;&|<>()]+)/
    |> Regex.scan(command, capture: :all_but_first)
    |> Enum.map(fn [target] -> String.trim(target, "\"") |> String.trim("'") end)
    |> Enum.reject(&String.starts_with?(&1, "&"))
  end

  defp temporary?(target) do
    full = target |> pi_path() |> Path.expand() |> real_path()
    Enum.any?(["/tmp", System.tmp_dir!()], &inside?(full, real_path(&1)))
  end
end
