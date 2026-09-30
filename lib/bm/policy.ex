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

  **Dependencies:** commands that install, add, remove or update dependencies are refused in
  every mode (plan 17.1): they change files git ignores, which BM can neither record nor undo.

  **This is a safety net, not a sandbox.** Shell parsing here is approximate: variables, `eval`,
  scripts and interpreters can do anything a permitted command can. Quoted text is an argument
  (`node -e 'x => x > 0'` writes nothing), except a `sh -c` or `eval` string, which is checked
  as a command, and double quotes holding `$(` or a backtick. A heredoc body is the command's
  input, unless a shell reads it (`bash <<EOF`, `cat <<EOF | sh`): then it is checked too. Snapshots attribute every
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

  # Package managers and the subcommands that install, add, remove or update dependencies.
  @dependency_tools ~w(npm pnpm yarn bun pip pip3 uv poetry pipenv bundle gem cargo mix go brew apt apt-get)
  @dependency_subcommands %{
    "npm" => ~w(install i ci add remove rm uninstall update up upgrade link),
    "pnpm" => ~w(install i add remove rm uninstall update up upgrade link import),
    "yarn" => ~w(install add remove upgrade up link),
    "bun" => ~w(install i add remove rm update link),
    "pip" => ~w(install uninstall),
    "pip3" => ~w(install uninstall),
    "uv" => ~w(add remove sync pip),
    "poetry" => ~w(install add remove update lock),
    "pipenv" => ~w(install uninstall update lock sync),
    "bundle" => ~w(install add remove update),
    "gem" => ~w(install uninstall update),
    "cargo" => ~w(add remove install uninstall update),
    "mix" => ~w(deps.get deps.update deps.unlock deps.clean archive.install),
    "go" => ~w(get install),
    "brew" => ~w(install uninstall upgrade update),
    "apt" => ~w(install remove upgrade update),
    "apt-get" => ~w(install remove upgrade update)
  }

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
    {command, shell_inputs} = heredocs(command)

    checks =
      Enum.map(redirect_targets(command), &{:write_target, &1}) ++
        Enum.map(segments(command), &{:segment, &1}) ++
        Enum.map(shell_inputs, &{:shell_input, &1})

    Enum.find_value(checks, :allow, fn
      {:write_target, target} -> denied(check_write_target(target, ctx))
      {:segment, tokens} -> denied(check_segment(tokens, ctx))
      {:shell_input, script} -> denied(authorize("bash", %{"command" => script}, ctx))
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
    masked = mask_quotes(command)

    {parts, from} =
      ~r/;|&&|\|\||\||&|\n|\$\(|`|\(|\)/
      |> Regex.scan(masked, return: :index)
      |> Enum.reduce({[], 0}, fn [{at, len}], {parts, from} ->
        {[binary_part(command, from, at - from) | parts], at + len}
      end)

    [binary_part(command, from, byte_size(command) - from) | parts]
    |> Enum.reverse()
    |> Enum.map(&words/1)
    |> Enum.reject(&(&1 == []))
  end

  @shells ~w(sh bash zsh dash ksh)

  # Heredoc bodies (`node <<'EOF'` … `EOF`) are the command's input, not shell (plan 19.2): they
  # are blanked. A body on a line that runs a shell (`bash <<EOF`, `cat <<EOF | sh`) is also
  # returned, to be checked as a command. Returns `{command with bodies blanked, shell inputs}`.
  defp heredocs(command), do: heredocs(command, "", [])

  defp heredocs(rest, done, inputs) do
    masked = mask_quotes(rest)

    with {at, delimiter, tabs?} <- next_heredoc(rest, masked),
         {newline, 1} <- :binary.match(masked, "\n", scope: {at, byte_size(masked) - at}) do
      body_from = newline + 1
      after_operator = binary_part(rest, body_from, byte_size(rest) - body_from)
      {body, after_body} = take_body(after_operator, delimiter, tabs?)
      inputs = if shell_line?(operator_line(rest, masked, at)), do: [body | inputs], else: inputs
      heredocs(after_body, done <> binary_part(rest, 0, body_from) <> blank(body), inputs)
    else
      _ -> {done <> rest, Enum.reverse(inputs)}
    end
  end

  # The first `<<WORD`, `<<-WORD`, `<<'WORD'` or `<<"WORD"` outside quotes (not `<<<`).
  defp next_heredoc(rest, masked) do
    ~r/(?<!<)<<(?!<)/
    |> Regex.scan(masked, return: :index)
    |> Enum.find_value(fn [{at, _}] ->
      case Regex.run(
             ~r/\A<<(-?)\s*(['"]?)([A-Za-z_][\w.-]*)\2/,
             binary_part(rest, at, byte_size(rest) - at)
           ) do
        [_, dash, _quote, delimiter] -> {at, delimiter, dash == "-"}
        nil -> nil
      end
    end)
  end

  # The body ends before the line holding only the delimiter (after tabs for `<<-`), or at the
  # end of the command.
  defp take_body(text, delimiter, tabs?) do
    tabs = if tabs?, do: "\t*", else: ""

    case Regex.run(~r/^#{tabs}#{Regex.escape(delimiter)}$/m, text, return: :index) do
      [{at, _}] -> {binary_part(text, 0, at), binary_part(text, at, byte_size(text) - at)}
      nil -> {text, ""}
    end
  end

  defp operator_line(rest, masked, at) do
    from =
      case :binary.matches(binary_part(masked, 0, at), "\n") do
        [] -> 0
        matches -> matches |> List.last() |> elem(0) |> Kernel.+(1)
      end

    to =
      case :binary.match(masked, "\n", scope: {at, byte_size(masked) - at}) do
        {newline, _} -> newline
        :nomatch -> byte_size(rest)
      end

    binary_part(rest, from, to - from)
  end

  defp shell_line?(line) do
    Enum.any?(segments(line), fn tokens ->
      case Enum.drop_while(tokens, &prefix_word?/1) do
        [cmd | _] -> Path.basename(cmd) in @shells
        [] -> false
      end
    end)
  end

  defp blank(text), do: for(<<byte <- text>>, into: "", do: if(byte == ?\n, do: "\n", else: " "))

  # Text in quotes is one word to the shell, not redirections or command separators, so
  # `node -e 'xs.map(x => x > 0)'` is one command (the reviewer's probes, plan 18, were refused
  # as writes to `x`). Quoted text is blanked byte for byte, so positions found in the mask cut
  # the original. Double quotes holding `$(` or a backtick stay visible: the shell runs those.
  defp mask_quotes(command) do
    Regex.replace(~r/(?<!\\)"(?:[^"\\]|\\.)*"|(?<!\\)'[^']*'/s, command, fn quoted ->
      if String.starts_with?(quoted, "\"") and String.contains?(quoted, ["$(", "`"]) do
        quoted
      else
        quote_char = binary_part(quoted, 0, 1)
        quote_char <> String.duplicate("_", byte_size(quoted) - 2) <> quote_char
      end
    end)
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

  # `sh -c "…"` and `eval "…"`: the string is a command of its own (quoted text is otherwise not
  # looked into, see mask_quotes/1).
  defp check_command(shell, args, ctx) when shell in @shells do
    case Enum.drop_while(args, &(not (&1 =~ ~r/^-[a-zA-Z]*c[a-zA-Z]*$/))) do
      [_flag, inner | _] -> authorize("bash", %{"command" => inner}, ctx)
      _ -> :allow
    end
  end

  defp check_command("eval", args, ctx),
    do: authorize("bash", %{"command" => Enum.join(args, " ")}, ctx)

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

  # Installing or changing dependencies changes the environment outside what BM records or can
  # undo (node_modules, deps/, site-packages are ignored by git). Seen in the first real run
  # (plan 17): a worker ran `pnpm install` to get a failing build going.
  defp check_command(cmd, args, _ctx) when cmd in @dependency_tools do
    if dependency_change?(cmd, args) do
      {:deny,
       "#{Enum.join([cmd | Enum.take(args, 1)], " ")} changes the project's dependencies or " <>
         "environment, which BM does not do. If the task needs it, report the task as blocked " <>
         "and name the command the user should run."}
    else
      # npm, mix, cargo and gem are also publishing tools (found by the test suite after
      # plan 17.1 had let `npm publish` through here).
      check_publishing(cmd, args)
    end
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

  defp check_command(cmd, args, _ctx), do: check_publishing(cmd, args)

  defp check_publishing(cmd, args) do
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

  # `yarn` alone installs; otherwise the first non-option argument is the subcommand.
  defp dependency_change?("yarn", args) do
    case Enum.reject(args, &String.starts_with?(&1, "-")) do
      [] -> true
      [sub | _] -> sub in @dependency_subcommands["yarn"]
    end
  end

  defp dependency_change?(cmd, args) do
    case Enum.reject(args, &String.starts_with?(&1, "-")) do
      [sub | _] -> sub in Map.get(@dependency_subcommands, cmd, [])
      [] -> false
    end
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
    |> Regex.scan(mask_quotes(command), capture: :all_but_first, return: :index)
    |> Enum.map(fn [{at, len}] ->
      command |> binary_part(at, len) |> String.trim("\"") |> String.trim("'")
    end)
    |> Enum.reject(&String.starts_with?(&1, "&"))
  end

  defp temporary?(target) do
    full = target |> pi_path() |> Path.expand() |> real_path()
    Enum.any?(["/tmp", System.tmp_dir!()], &inside?(full, real_path(&1)))
  end
end
