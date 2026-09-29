defmodule Bm.Workspace.Git do
  @moduledoc """
  BM's git layer: snapshots, write sets, baselines, checkpoints and conditional restore
  (docs/ARCHITECTURE.md §7, decisions D11, D12, D19). Every function takes the repository path.

  **It never touches the user's git state.** Snapshots use BM's own index file
  (`<git-dir>/bm/index`), never `.git/index`; checkpoints are commits under `refs/bm/…`, never on a
  branch; `git status` runs with `GIT_OPTIONAL_LOCKS=0`, because a plain `git status` rewrites
  the user's index to refresh its stat cache. Paths are literal (`GIT_LITERAL_PATHSPECS=1`).

  A snapshot is the tree id of the whole working tree (tracked and untracked, not ignored). The
  private index keeps git's stat cache, so repeated snapshots only re-hash changed files.
  """

  @env [
    {"GIT_LITERAL_PATHSPECS", "1"},
    {"GIT_OPTIONAL_LOCKS", "0"},
    {"GIT_TERMINAL_PROMPT", "0"},
    {"LC_ALL", "C"}
  ]

  # Checkpoints are BM's commits; this identity avoids depending on the user's git config.
  @identity [
    {"GIT_AUTHOR_NAME", "BM"},
    {"GIT_AUTHOR_EMAIL", "bm@localhost"},
    {"GIT_COMMITTER_NAME", "BM"},
    {"GIT_COMMITTER_EMAIL", "bm@localhost"}
  ]

  @type tree :: String.t()
  @type entry :: %{path: String.t(), status: :added | :modified | :deleted}

  ## Snapshots (D19)

  @doc "Tree id of the working tree, written from BM's private index."
  @spec snapshot(Path.t()) :: {:ok, tree} | {:error, term()}
  def snapshot(repo) do
    with {:ok, index} <- private_index(repo),
         :ok <- prepare_index(repo, index),
         :ok <- add_all(repo, index) do
      git(repo, ["write-tree"], index: index) |> trimmed()
    end
  end

  defp private_index(repo) do
    with {:ok, git_dir} <- git_dir(repo),
         dir = Path.join(git_dir, "bm"),
         :ok <- File.mkdir_p(dir) |> tag_error(:private_dir) do
      {:ok, Path.join(dir, "index")}
    end
  end

  # A workspace is a whole checkout: `repo` must be the repository's top level, not a
  # subdirectory (which would snapshot only part of it, or a directory the parent repo ignores).
  defp git_dir(repo) do
    with {:ok, out} <-
           git(repo, ["rev-parse", "--absolute-git-dir", "--show-toplevel"], stderr: true),
         [git_dir, top] <- String.split(out, "\n", trim: true) do
      {real, 0} = System.cmd("pwd", ["-P"], cd: repo)
      if top == String.trim(real), do: {:ok, git_dir}, else: {:error, {:not_repository_root, top}}
    else
      {:error, _} = error -> error
      _ -> {:error, :bare_repository}
    end
  end

  # The first snapshot starts from HEAD (so git can reuse its hashes); later ones reuse the index.
  defp prepare_index(repo, index) do
    if File.exists?(index) do
      :ok
    else
      args = if head(repo), do: ["read-tree", "HEAD"], else: ["read-tree", "--empty"]
      git(repo, args, index: index) |> ok()
    end
  end

  defp add_all(repo, index) do
    case git(repo, ["add", "-A", "--", "."], index: index, stderr: true) do
      {:ok, _} ->
        :ok

      # A damaged private index is only a cache: rebuild it once.
      {:error, _} ->
        File.rm(index)

        with :ok <- prepare_index(repo, index),
             do: git(repo, ["add", "-A", "--", "."], index: index, stderr: true) |> ok()
    end
  end

  @doc "`:ok` if `repo` is the top level of a git working tree, `{:error, reason}` otherwise."
  def check_root(repo) do
    with {:ok, _git_dir} <- git_dir(repo), do: :ok
  end

  @doc "The object id `rev` names (e.g. a checkpoint ref), or nil."
  def rev_parse(repo, rev) do
    case git(repo, ["rev-parse", "--verify", "--quiet", rev]) do
      {:ok, out} -> String.trim(out)
      {:error, _} -> nil
    end
  end

  @doc "HEAD's commit id, or nil in a repository without commits."
  def head(repo) do
    case git(repo, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]) do
      {:ok, out} -> String.trim(out)
      {:error, _} -> nil
    end
  end

  ## Write sets (D11)

  @doc "Paths that differ between two trees (renames appear as a delete and an add)."
  @spec diff(Path.t(), tree, tree) :: {:ok, [entry]} | {:error, term()}
  def diff(repo, tree_a, tree_b) do
    args = ["diff-tree", "-r", "-z", "--no-renames", "--name-status", tree_a, tree_b]

    with {:ok, out} <- git(repo, args) do
      {:ok, out |> String.split(<<0>>, trim: true) |> parse_name_status([])}
    end
  end

  defp parse_name_status([status, path | rest], acc) do
    parse_name_status(rest, [%{path: path, status: status_atom(status)} | acc])
  end

  defp parse_name_status([], acc), do: Enum.reverse(acc)

  defp status_atom("A"), do: :added
  defp status_atom("D"), do: :deleted
  # M (content), T (type, e.g. file ↔ symlink).
  defp status_atom(_), do: :modified

  ## Baseline

  @doc """
  The state at run start: HEAD, a snapshot tree, and the **user-owned** paths: everything
  staged, modified or untracked (not ignored). BM must not change those during the run.
  """
  @spec baseline(Path.t()) ::
          {:ok, %{head: String.t() | nil, tree: tree, user_owned: [String.t()]}}
  def baseline(repo) do
    args = ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"]

    with {:ok, tree} <- snapshot(repo),
         {:ok, out} <- git(repo, args) do
      user_owned =
        for record <- String.split(out, <<0>>, trim: true),
            <<_xy::binary-size(2), " ", path::binary>> <- [record],
            do: path

      {:ok, %{head: head(repo), tree: tree, user_owned: Enum.sort(user_owned)}}
    end
  end

  ## Checkpoints (D12)

  @doc """
  Records `tree` as a commit under `ref` (which must be under `refs/bm/` and must not exist yet).
  `parent` is the previous checkpoint or HEAD (nil for none). Nothing else changes.
  """
  @spec checkpoint(Path.t(), tree, String.t() | nil, String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def checkpoint(repo, tree, parent, "refs/bm/" <> _ = ref, message) do
    parents = if parent, do: ["-p", parent], else: []

    with {:ok, _} <- git(repo, ["check-ref-format", ref]),
         {:ok, commit} <-
           git(repo, ["commit-tree", "--no-gpg-sign", tree | parents] ++ ["-m", message],
             env: @identity
           )
           |> trimmed(),
         # The empty old value makes git refuse if the ref already exists.
         {:ok, _} <-
           git(repo, ["update-ref", "-m", "bm checkpoint", ref, commit, ""], stderr: true) do
      {:ok, commit}
    end
  end

  def checkpoint(_repo, _tree, _parent, ref, _message), do: {:error, {:not_a_bm_ref, ref}}

  ## Conditional restore

  @doc """
  Puts the files in `entries` back to their content in `from_tree`, but only if every one of them
  still has exactly its content in `expected_tree` (absent if absent there). Otherwise returns
  `{:error, {:changed_since, paths}}` and changes nothing. Files absent in `from_tree` are
  deleted. Used to revert an attempt: `from_tree` is its `tree_before`, `expected_tree` its
  `tree_after`.

  **All or nothing, also against concurrent edits.** Everything is read from git first. Then each
  file to replace is moved aside (an atomic rename into `<git-dir>/bm/restore-*`), the moved
  copies are checked again (an editor saving to the path now creates a new file instead of
  changing ours), and the old contents are written with exclusive create, so a file that appears
  meanwhile is never overwritten. On any failure every step is undone. If the user created a
  file at a moved path in that window, their file is kept, BM's copy stays in the stash and the
  result is `{:error, {:interrupted, reason, stash: dir}}`.

  `opts[:after_move]` (tests only) runs after the files are moved aside.
  """
  @spec restore(
          Path.t(),
          [entry | %{String.t() => String.t()} | String.t()],
          tree,
          tree,
          keyword()
        ) :: :ok | {:error, term()}
  def restore(repo, entries, from_tree, expected_tree, opts \\ []) do
    paths = entries |> Enum.map(&entry_path/1) |> Enum.uniq()

    with {:ok, git_dir} <- git_dir(repo),
         {:ok, expected} <- ls_tree(repo, expected_tree, paths),
         {:ok, from} <- ls_tree(repo, from_tree, paths),
         {:ok, current} <- current_objects(repo, paths),
         deletes = Enum.filter(paths, &(from[&1] == nil and current[&1] != :directory)),
         [] <- changed_paths(repo, paths, current, expected, MapSet.new(deletes)),
         {:ok, contents} <- read_contents(repo, from) do
      swap(repo, git_dir, paths, expected, contents, opts)
    else
      changed when is_list(changed) -> {:error, {:changed_since, changed}}
      error -> error
    end
  end

  # Paths whose current state isn't what the attempt left. A directory where the attempt left
  # nothing (it created files below it) is fine only if the restore deletes everything in it.
  defp changed_paths(repo, paths, current, expected, deletes) do
    Enum.reject(paths, fn path ->
      case current[path] do
        :directory -> expected[path] == nil and directory_cleared?(repo, path, deletes)
        object -> object == expected[path]
      end
    end)
  end

  defp directory_cleared?(repo, dir, deletes) do
    root = Path.expand(repo)

    Path.join([root, dir, "**"])
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.all?(&MapSet.member?(deletes, Path.relative_to(&1, root)))
  end

  defp depth(path), do: path |> Path.split() |> length()

  defp entry_path(%{path: path}), do: path
  # As stored in `attempts.actual_writes` (JSON: string keys).
  defp entry_path(%{"path" => path}), do: path
  defp entry_path(path) when is_binary(path), do: path

  # %{path => {mode, blob}} for the paths present in `tree`.
  defp ls_tree(_repo, _tree, []), do: {:ok, %{}}

  defp ls_tree(repo, tree, paths) do
    with {:ok, out} <- git(repo, ["ls-tree", "-r", "-z", "--full-tree", tree, "--" | paths]) do
      objects =
        for record <- String.split(out, <<0>>, trim: true),
            [meta, path] <- [String.split(record, "\t", parts: 2)],
            [mode, _type, blob] <- [String.split(meta, " ")],
            into: %{},
            do: {path, {mode, blob}}

      {:ok, objects}
    end
  end

  # %{path => {mode, blob} | :directory} for the paths that exist, hashed as git would.
  defp current_objects(repo, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
      case object_at(repo, Path.join(repo, path), path) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, object} -> {:cont, {:ok, Map.put(acc, path, object)}}
        error -> {:halt, error}
      end
    end)
  end

  # The git object for the file at `full`, hashed with the attributes of repository path `path`
  # (so a file moved into the stash hashes as it did in place). nil if absent.
  defp object_at(repo, full, path) do
    case File.lstat(full) do
      # :enotdir: a parent is a file, so this path doesn't exist either.
      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:ok, nil}

      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, target} = File.read_link(full)
        hash(repo, ["hash-object", "--stdin"], target, "120000")

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        file_mode = if Bitwise.band(mode, 0o111) != 0, do: "100755", else: "100644"
        hash(repo, ["hash-object", "--path=#{path}", "--", Path.expand(full)], nil, file_mode)

      {:ok, %File.Stat{type: :directory}} ->
        {:ok, :directory}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsupported_file_type, path, type}}

      {:error, reason} ->
        {:error, {:lstat, path, reason}}
    end
  end

  defp hash(repo, args, input, mode) do
    with {:ok, blob} <- git(repo, args, input: input) |> trimmed(), do: {:ok, {mode, blob}}
  end

  # Contents to write, read before any file is touched: %{path => {:file, data, mode} | {:link, target}}.
  defp read_contents(repo, from) do
    Enum.reduce_while(from, {:ok, %{}}, fn
      {path, {"120000", blob}}, {:ok, acc} ->
        case git(repo, ["cat-file", "blob", blob]) do
          {:ok, target} -> {:cont, {:ok, Map.put(acc, path, {:link, target})}}
          error -> {:halt, error}
        end

      {path, {mode, blob}}, {:ok, acc} ->
        # --filters applies the checkout conversions (eol, smudge) for this path.
        case git(repo, ["cat-file", "--filters", "--path=#{path}", blob]) do
          {:ok, data} -> {:cont, {:ok, Map.put(acc, path, {:file, data, mode})}}
          error -> {:halt, error}
        end
    end)
  end

  defp swap(repo, git_dir, paths, expected, contents, opts) do
    stash = Path.join([git_dir, "bm", "restore-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(stash)
    journal = %{moved: [], written: []}

    result =
      with {:ok, journal} <- move_aside(repo, stash, paths, journal),
           _ = if(hook = opts[:after_move], do: hook.()),
           :ok <- verify_moved(repo, paths, expected, journal),
           {:ok, journal} <- write_all(repo, contents, journal) do
        {:ok, journal}
      end

    case result do
      {:ok, _journal} ->
        File.rm_rf!(stash)
        :ok

      {:error, reason, journal} ->
        case undo(repo, journal) do
          [] ->
            File.rm_rf!(stash)
            {:error, reason}

          _kept ->
            {:error, {:interrupted, reason, stash: stash}}
        end
    end
  end

  # Deepest first, so directories empty out before files take their place.
  defp move_aside(repo, stash, paths, journal) do
    paths
    |> Enum.sort_by(&depth/1, :desc)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, journal}, fn {path, i}, {:ok, journal} ->
      full = Path.join(repo, path)
      aside = Path.join(stash, Integer.to_string(i))

      case File.lstat(full) do
        {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] ->
          case File.rename(full, aside) do
            :ok ->
              remove_empty_parents(repo, Path.dirname(full))
              {:cont, {:ok, %{journal | moved: [{path, aside} | journal.moved]}}}

            {:error, reason} ->
              {:halt, {:error, {:move_aside, path, reason}, journal}}
          end

        _directory_or_absent ->
          {:cont, {:ok, journal}}
      end
    end)
  end

  # The moved copies must still be what the attempt left, and nothing may have appeared at the
  # paths that were absent.
  defp verify_moved(repo, paths, expected, journal) do
    moved = Map.new(journal.moved)

    changed =
      Enum.reject(paths, fn path ->
        case Map.fetch(moved, path) do
          {:ok, aside} -> object_at(repo, aside, path) == {:ok, expected[path]}
          :error -> expected[path] == nil and absent_or_directory?(Path.join(repo, path))
        end
      end)

    if changed == [], do: :ok, else: {:error, {:changed_since, changed}, journal}
  end

  defp absent_or_directory?(full) do
    case File.lstat(full) do
      {:ok, %File.Stat{type: :directory}} -> true
      {:ok, _} -> false
      {:error, _} -> true
    end
  end

  # Shallowest first; exclusive create never overwrites a file that appeared meanwhile.
  defp write_all(repo, contents, journal) do
    contents
    |> Enum.sort_by(fn {path, _} -> depth(path) end)
    |> Enum.reduce_while({:ok, journal}, fn {path, content}, {:ok, journal} ->
      case write_new(Path.join(repo, path), content) do
        :ok ->
          {:cont, {:ok, %{journal | written: [path | journal.written]}}}

        {:error, :eexist} ->
          {:halt, {:error, {:changed_since, [path]}, journal}}

        {:error, reason} ->
          {:halt, {:error, {:write, path, reason}, journal}}
      end
    end)
  end

  defp write_new(full, content) do
    with :ok <- File.mkdir_p(Path.dirname(full)),
         :ok <- remove_empty_dir(full) do
      case content do
        {:link, target} ->
          File.ln_s(target, full)

        {:file, data, mode} ->
          with {:ok, io} <- File.open(full, [:write, :exclusive, :binary]) do
            IO.binwrite(io, data)
            File.close(io)
            File.chmod(full, if(mode == "100755", do: 0o755, else: 0o644))
          end
      end
    end
  end

  # A directory the attempt created where a file must return; it is empty by now or the write
  # fails (a file inside it appeared meanwhile).
  defp remove_empty_dir(full) do
    case File.lstat(full) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.rmdir(full) do
          :ok -> :ok
          {:error, _} -> {:error, :eexist}
        end

      _ ->
        :ok
    end
  end

  # Removes what was written and moves the stashed files back. Returns the paths that could not
  # be moved back because something now occupies them (their copies stay in the stash).
  defp undo(repo, journal) do
    for path <- journal.written do
      full = Path.join(repo, path)
      File.rm(full)
      remove_empty_parents(repo, Path.dirname(full))
    end

    journal.moved
    |> Enum.reverse()
    |> Enum.reject(fn {path, aside} -> move_back(Path.join(repo, path), aside) == :ok end)
    |> Enum.map(fn {path, _aside} -> path end)
  end

  defp move_back(full, aside) do
    with :ok <- File.mkdir_p(Path.dirname(full)),
         {:error, _absent} <- File.lstat(full) do
      File.rename(aside, full)
    else
      {:ok, _occupied} -> {:error, :occupied}
      error -> error
    end
  end

  defp remove_empty_parents(repo, dir) do
    root = Path.expand(repo)

    if Path.expand(dir) != root and File.ls(dir) == {:ok, []} do
      File.rmdir(dir)
      remove_empty_parents(repo, Path.dirname(dir))
    end
  end

  ## Running git

  defp git(repo, args, opts \\ []) do
    env =
      @env ++
        Keyword.get(opts, :env, []) ++
        if(opts[:index], do: [{"GIT_INDEX_FILE", opts[:index]}], else: [])

    cmd_opts = [cd: repo, env: env, stderr_to_stdout: Keyword.get(opts, :stderr, false)]

    result =
      case opts[:input] do
        nil -> System.cmd("git", args, cmd_opts)
        input -> run_with_input(args, input, cmd_opts)
      end

    case result do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {:git, hd(args), status, String.slice(out, 0, 2_000)}}
    end
  end

  # System.cmd has no stdin; git reads the input from a temporary file instead.
  defp run_with_input(args, input, cmd_opts) do
    path = Path.join(System.tmp_dir!(), "bm-git-#{System.unique_integer([:positive])}")
    File.write!(path, input)

    try do
      System.cmd("sh", ["-c", ~s(exec git "$@" < "$0"), path | args], cmd_opts)
    after
      File.rm(path)
    end
  end

  defp tag_error(:ok, _tag), do: :ok
  defp tag_error({:error, reason}, tag), do: {:error, {tag, reason}}

  defp trimmed({:ok, out}), do: {:ok, String.trim(out)}
  defp trimmed(error), do: error

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error
end
