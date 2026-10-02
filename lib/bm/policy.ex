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

  **Commands that run commands** (plan 36.4) are checked as what they run: `timeout`, `nice`,
  `env`, `command`, `exec`, `time`, `stdbuf`, `ionice`, `caffeinate`, `watch`, `xargs` and
  `find -exec`. git configuration that changes what git runs is refused (`git -c alias.*|core.*|
  include.*`, `--config-env`, `GIT_CONFIG_*` and `GIT_DIR`-style variables), and a git
  subcommand BM doesn't know is looked up as one of the user's aliases. A shell reading commands
  from its input (`curl … | sh`) is refused. Files under `.pi/` (the agents' own settings) are
  never written.

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
  @git_writes ~w(add am apply bisect checkout checkout-index cherry-pick clean clone commit
                 commit-tree fast-import fetch filter-branch gc hash-object init merge mv notes
                 prune pull push read-tree rebase reflog remote repack replace reset restore
                 revert rm sparse-checkout submodule switch symbolic-ref update-index update-ref
                 worktree)
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
    # `cat <<EOF | sh`: the shell reads a heredoc that is checked below.
    ctx = if shell_inputs != [], do: Map.put(ctx, :reads_heredoc, true), else: ctx

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

      inside?(String.downcase(full), String.downcase(Path.join(root, ".git"))) ->
        {:deny, "BM manages git itself; don't change files in .git."}

      # pi reads a project's .pi/ (settings with the shell it runs, system prompts): a change
      # there would change the next agent (plan 36.4).
      inside?(String.downcase(full), String.downcase(Path.join(root, ".pi"))) ->
        {:deny, "Files in .pi/ configure the coding agents; BM doesn't let agents change them."}

      # Compared without case: on macOS NOTES.md is the user's notes.md.
      user_owned?(Path.relative_to(full, root), ctx.user_owned) ->
        {:deny,
         "#{Path.relative_to(full, root)} has uncommitted changes of the user; BM must not " <>
           "change it. Report that the task needs it instead."}

      true ->
        :allow
    end
  end

  defp user_owned?(relative, owned) do
    relative = String.downcase(relative)
    Enum.any?(owned, &(String.downcase(&1) == relative))
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

  # Resolves symlinks in every existing component; the missing tail is kept as is. It runs inside
  # the coordinator, so it must always return: after 40 symlinks (a loop, like the system's
  # ELOOP) or on a directory it can't enter, the path becomes one no workspace contains.
  @max_links 40
  @unresolvable "/nonexistent/bm-unresolvable-path"

  defp real_path(path), do: real_path(path, @max_links)

  defp real_path(_path, 0), do: @unresolvable

  defp real_path(path, links) do
    path = Path.expand(path)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} -> target |> Path.expand(Path.dirname(path)) |> real_path(links - 1)
          {:error, _} -> @unresolvable
        end

      {:ok, %File.Stat{type: :directory}} ->
        case System.cmd("pwd", ["-P"], cd: path, stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> @unresolvable
        end

      _file_or_missing ->
        parent = Path.dirname(path)

        if parent == path,
          do: path,
          else: Path.join(real_path(parent, links), Path.basename(path))
    end
  rescue
    _ -> @unresolvable
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

  # How deep wrappers may nest (`timeout 9 nice xargs env git …`) before BM refuses to guess.
  @max_depth 8

  defp check_segment(tokens, ctx), do: check_tokens(tokens, ctx, @max_depth)

  defp check_tokens(_tokens, _ctx, 0),
    do: {:deny, "This command nests too many wrapper commands for BM to check; run it directly."}

  defp check_tokens(tokens, ctx, depth) do
    {assignments, rest} = Enum.split_while(tokens, &prefix_word?/1)

    with :allow <- check_assignments(assignments) do
      case rest do
        [] ->
          :allow

        [cmd | args] ->
          name = Path.basename(cmd)

          # Wrappers run their arguments as a command (`timeout 60 git push`, `find -exec`,
          # `xargs rm`): the command itself is checked, then the one it runs.
          with :allow <- check_command(name, args, ctx) do
            name
            |> inner_commands(args)
            |> Enum.find_value(:allow, &denied(check_tokens(&1, ctx, depth - 1)))
          end
      end
    end
  end

  defp prefix_word?(word), do: word in ~w(nohup builtin) or assignment?(word)

  defp assignment?(word), do: word =~ ~r/^[A-Za-z_]\w*=/

  # git reads extra configuration from the environment; `alias.*` there runs any command.
  @git_env ~w(GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
              GIT_EXEC_PATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY)

  defp check_assignments(words) do
    case Enum.find(words, &git_env?/1) do
      nil -> :allow
      word -> {:deny, "Setting #{variable(word)} changes how git works here; leave git to BM."}
    end
  end

  defp git_env?(word) do
    name = variable(word)
    name in @git_env or String.starts_with?(name, "GIT_CONFIG_KEY_")
  end

  defp variable(word), do: word |> String.split("=", parts: 2) |> hd()

  ## Commands that run other commands

  # The commands a wrapper runs, as word lists (none for other commands).
  defp inner_commands("env", args), do: env_command(args)
  defp inner_commands("nice", args), do: [drop_options(args, ~w(-n --adjustment))]
  defp inner_commands("nohup", args), do: [args]
  defp inner_commands("time", args), do: [drop_options(args, ~w(-f --format -o --output))]
  defp inner_commands("exec", args), do: [drop_options(args, ~w(-a))]
  defp inner_commands("stdbuf", args), do: [drop_options(args, ~w(-i -o -e))]
  defp inner_commands("ionice", args), do: [drop_options(args, ~w(-c -n -p -P -u))]
  defp inner_commands("caffeinate", args), do: [drop_options(args, ~w(-t -w))]
  defp inner_commands("watch", args), do: [drop_options(args, ~w(-n --interval -d))]
  defp inner_commands("chronic", args), do: [drop_options(args, [])]
  defp inner_commands("unbuffer", args), do: [drop_options(args, [])]

  # `timeout [options] DURATION command …`
  defp inner_commands("timeout", args) do
    case drop_options(args, ~w(-s --signal -k --kill-after)) do
      [_duration | command] -> [command]
      [] -> []
    end
  end

  # `command -v x` only prints where x is; `command [-p] x …` runs it.
  defp inner_commands("command", args) do
    if Enum.any?(args, &(&1 in ["-v", "-V"])), do: [], else: [drop_options(args, [])]
  end

  defp inner_commands("xargs", args) do
    case drop_options(args, ~w(-I -L -n -P -s -d -E -a --max-args --max-lines --max-procs
                                --delimiter --arg-file --max-chars --replace --process-slot-var)) do
      [] -> []
      command -> [command]
    end
  end

  # Every `-exec … ;`, `-execdir … +`, `-ok …`, `-okdir …` of a find.
  defp inner_commands("find", args), do: find_execs(args, [])

  defp inner_commands(_name, _args), do: []

  defp find_execs([action | rest], acc) when action in ~w(-exec -execdir -ok -okdir) do
    {command, after_command} = Enum.split_while(rest, &(&1 not in [";", "\\;", "+"]))
    find_execs(Enum.drop(after_command, 1), [command | acc])
  end

  defp find_execs([_ | rest], acc), do: find_execs(rest, acc)
  defp find_execs([], acc), do: Enum.reverse(acc)

  # `env [-i] [-u NAME] [-C DIR] [NAME=value]… command …`; `-S "string"` is a command line.
  defp env_command(args) do
    case args do
      [split, line | rest] when split in ["-S", "--split-string"] ->
        [words(line) ++ rest]

      ["--split-string=" <> line | rest] ->
        [words(line) ++ rest]

      _ ->
        [drop_options(args, ~w(-u --unset -C --chdir))]
    end
  end

  # Drops leading options (and the values of those in `with_value`) up to the first operand.
  defp drop_options(["--" | rest], _with_value), do: rest

  defp drop_options(["-" <> _ = option | rest], with_value) do
    case rest do
      [_value | after_value] ->
        if option in with_value,
          do: drop_options(after_value, with_value),
          else: drop_options(rest, with_value)

      [] ->
        []
    end
  end

  defp drop_options(rest, _with_value), do: rest

  defp check_command("git", args, ctx), do: check_git(args, ctx, @max_depth)

  defp check_command("export", args, _ctx),
    do: check_assignments(Enum.filter(args, &assignment?/1))

  # `find -delete` deletes under its starting points; `-fprint` and `-fls` write a file.
  defp check_command("find", args, ctx) do
    starts = Enum.take_while(args, &(not String.starts_with?(&1, ["-", "(", "!"])))

    writes =
      args
      |> Enum.chunk_every(2, 1)
      |> Enum.flat_map(fn
        [option, file] when option in ~w(-fprint -fprint0 -fls -fprintf) -> [file]
        _ -> []
      end)

    deletes = if "-delete" in args, do: if(starts == [], do: ["."], else: starts), else: []
    check_write_targets(writes ++ deletes, ctx)
  end

  # `sh -c "…"` and `eval "…"`: the string is a command of its own (quoted text is otherwise not
  # looked into, see mask_quotes/1).
  # A shell with neither `-c` nor a script reads its commands from its input (`curl … | sh`),
  # which BM can't see (a heredoc it reads is checked, see heredocs/1).
  defp check_command(shell, args, ctx) when shell in @shells do
    case Enum.drop_while(args, &(not (&1 =~ ~r/^-[a-zA-Z]*c[a-zA-Z]*$/))) do
      [_flag, inner | _] ->
        authorize("bash", %{"command" => inner}, ctx)

      _ ->
        if operands(args) == [] and !ctx[:reads_heredoc] and
             not Enum.any?(args, &(&1 in ["--version", "--help"])),
           do:
             {:deny,
              "#{shell} reading commands from its input can't be checked; run the commands " <>
                "directly or from a script file."},
           else: :allow
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
    case subcommand_words(args) do
      [] -> true
      [sub | _] -> sub in @dependency_subcommands["yarn"]
    end
  end

  defp dependency_change?(cmd, args) do
    case subcommand_words(args) do
      [sub | _] -> sub in Map.get(@dependency_subcommands, cmd, [])
      [] -> false
    end
  end

  # Options of package managers that take a separate value (`npm --prefix dir install`).
  @options_with_value ~w(-C --prefix --cwd --dir --filter -F --workspace --manifest-path
                         --target --project --directory)

  defp subcommand_words([opt, _value | rest]) when opt in @options_with_value,
    do: subcommand_words(rest)

  defp subcommand_words(["-" <> _ | rest]), do: subcommand_words(rest)
  defp subcommand_words(words), do: words

  # git subcommands that only read (anything else may be an alias of the user's).
  @git_reads ~w(status log diff show grep ls-files ls-tree ls-remote cat-file rev-parse rev-list
                blame annotate describe shortlog show-ref show-branch for-each-ref name-rev
                merge-base whatchanged diff-tree diff-files diff-index cherry count-objects var
                version help check-ignore check-attr check-ref-format verify-commit verify-tag
                range-diff format-patch archive branch config tag stash)

  defp check_git(_args, _ctx, 0), do: {:deny, "This git alias nests too deeply for BM to check."}

  defp check_git(args, ctx, depth) do
    with :allow <- check_git_options(args) do
      case git_subcommand(args) do
        {sub, rest} ->
          cond do
            git_write?(sub, rest) ->
              {:deny,
               "git #{sub} changes the repository. BM records and checkpoints changes itself; " <>
                 "leave git to BM and only edit files."}

            sub in @git_reads ->
              :allow

            true ->
              check_git_alias(sub, rest, ctx, depth)
          end

        nil ->
          :allow
      end
    end
  end

  # `git -c alias.x='!cmd' x` runs any command; `core.*` and `include.*` change what git runs
  # (hooks, pager, fsmonitor) or which configuration it reads.
  defp check_git_options(args) do
    args
    |> Enum.take_while(&String.starts_with?(&1, "-"))
    |> length()
    |> then(&Enum.take(args, &1 * 2 + 1))
    |> Enum.chunk_every(2, 1)
    |> Enum.find_value(:allow, fn
      ["-c", setting | _] ->
        key = setting |> String.split("=", parts: 2) |> hd() |> String.downcase()

        if String.starts_with?(key, ["alias.", "core.", "include.", "includeif."]),
          do: {:deny, "git -c #{key} changes what git runs; leave git's configuration alone."}

      ["--config-env" <> _ | _] ->
        {:deny, "git --config-env changes git's configuration; leave it alone."}

      ["--exec-path=" <> _ | _] ->
        {:deny, "git --exec-path=… changes the programs git runs; leave it alone."}

      _ ->
        nil
    end)
  end

  # An alias in the user's git configuration (`git co` = `git checkout`) is checked as what it
  # runs: `!…` as a shell command, otherwise as git with those words.
  defp check_git_alias(sub, rest, ctx, depth) do
    case System.cmd("git", ["config", "--get", "alias." <> sub],
           cd: ctx.root,
           env: [{"GIT_OPTIONAL_LOCKS", "0"}],
           stderr_to_stdout: true
         ) do
      {"!" <> command, 0} ->
        authorize(
          "bash",
          %{"command" => String.trim(command) <> " " <> Enum.join(rest, " ")},
          ctx
        )

      {expansion, 0} ->
        check_git(words(String.trim(expansion)) ++ rest, ctx, depth - 1)

      _ ->
        :allow
    end
  rescue
    _ -> :allow
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

  # `.git/config` is outside every snapshot (like dependencies): only reading it is fine.
  defp git_write?("config", rest) do
    reads = ~w(-l --list --get --get-all --get-regexp --show-origin --show-scope)

    cond do
      Enum.any?(rest, &(&1 in reads)) -> false
      # `git config user.name`: one key, no value, no option, reads it.
      match?([key] when binary_part(key, 0, 1) != "-", rest) -> false
      true -> true
    end
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

      temporary?(target, ctx.root) ->
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

  # Relative targets are relative to the workspace (where the command runs), not to BM. A
  # workspace may itself lie in a temp directory: its files follow the workspace rules.
  defp temporary?(target, root) do
    full = target |> pi_path() |> Path.expand(root) |> real_path()

    not inside?(full, real_path(root)) and
      Enum.any?(["/tmp", System.tmp_dir!()], &inside?(full, real_path(&1)))
  end
end
