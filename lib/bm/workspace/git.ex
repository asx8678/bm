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
    with {:ok, git_dir} <- git_dir(repo) do
      dir = Path.join(git_dir, "bm")
      File.mkdir_p!(dir)
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
  """
  @spec restore(Path.t(), [entry | %{String.t() => String.t()} | String.t()], tree, tree) ::
          :ok | {:error, {:changed_since, [String.t()]}} | {:error, term()}
  def restore(repo, entries, from_tree, expected_tree) do
    paths = entries |> Enum.map(&entry_path/1) |> Enum.uniq()

    with {:ok, expected} <- ls_tree(repo, expected_tree, paths),
         {:ok, from} <- ls_tree(repo, from_tree, paths),
         {:ok, current} <- current_objects(repo, paths),
         deletes = Enum.filter(paths, &(from[&1] == nil and current[&1] != :directory)),
         [] <- changed_paths(repo, paths, current, expected, MapSet.new(deletes)) do
      # Deletions first, deepest first, so a directory is empty before a file takes its place
      # (an attempt that turned file `a` into `a/b` is reverted by removing `a/b`, then `a`).
      deletes |> Enum.sort_by(&depth/1, :desc) |> Enum.each(&delete_file(repo, &1))

      paths
      |> Enum.filter(&from[&1])
      |> Enum.sort_by(&depth/1)
      |> Enum.each(&write_file(repo, &1, from[&1]))
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

  # %{path => {mode, blob}} for the paths that exist in the working tree, hashed as git would.
  defp current_objects(repo, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
      full = Path.join(repo, path)

      case File.lstat(full) do
        # :enotdir: a parent is a file, so this path doesn't exist either.
        {:error, reason} when reason in [:enoent, :enotdir] ->
          {:cont, {:ok, acc}}

        {:ok, %File.Stat{type: :symlink}} ->
          {:ok, target} = File.read_link(full)
          hash_result(repo, ["hash-object", "--stdin"], target, "120000", path, acc)

        {:ok, %File.Stat{type: :regular, mode: mode}} ->
          file_mode = if Bitwise.band(mode, 0o111) != 0, do: "100755", else: "100644"
          hash_result(repo, ["hash-object", "--", path], nil, file_mode, path, acc)

        {:ok, %File.Stat{type: :directory}} ->
          {:cont, {:ok, Map.put(acc, path, :directory)}}

        {:ok, %File.Stat{type: type}} ->
          {:halt, {:error, {:unsupported_file_type, path, type}}}
      end
    end)
  end

  defp hash_result(repo, args, input, mode, path, acc) do
    case git(repo, args, input: input) |> trimmed() do
      {:ok, blob} -> {:cont, {:ok, Map.put(acc, path, {mode, blob})}}
      error -> {:halt, error}
    end
  end

  defp delete_file(repo, path) do
    full = Path.join(repo, path)
    File.rm(full)
    remove_empty_parents(repo, Path.dirname(full))
  end

  defp write_file(repo, path, {mode, blob}) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))

    case File.lstat(full) do
      {:ok, %File.Stat{type: :directory}} -> File.rmdir!(full)
      {:ok, _} -> File.rm!(full)
      {:error, _absent} -> :ok
    end

    case mode do
      "120000" ->
        {:ok, target} = git(repo, ["cat-file", "blob", blob])
        File.ln_s!(target, full)

      _ ->
        # --filters applies the checkout conversions (eol, smudge) for this path.
        {:ok, content} = git(repo, ["cat-file", "--filters", "--path=#{path}", blob])
        File.write!(full, content)
        File.chmod!(full, if(mode == "100755", do: 0o755, else: 0o644))
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

  defp trimmed({:ok, out}), do: {:ok, String.trim(out)}
  defp trimmed(error), do: error

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error
end
