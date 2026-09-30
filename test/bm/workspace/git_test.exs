defmodule Bm.Workspace.GitTest do
  use ExUnit.Case, async: true

  alias Bm.Workspace.Git

  @moduletag :tmp_dir

  defp git!(repo, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.name=User", "-c", "user.email=user@example.com" | args],
        cd: repo,
        # Like BM, never let a check refresh (rewrite) the user's index.
        env: [{"GIT_OPTIONAL_LOCKS", "0"}],
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp write!(repo, path, content) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp read(repo, path), do: File.read(Path.join(repo, path))

  # A repository with one commit and every kind of user state: a staged change, an unstaged
  # modification, an untracked file and an ignored file.
  defp fixture!(%{tmp_dir: dir}) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    write!(repo, ".gitignore", "*.log\n")
    write!(repo, "tracked.txt", "tracked\n")
    write!(repo, "staged.txt", "staged v1\n")
    write!(repo, "unstaged.txt", "unstaged v1\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "initial"])

    write!(repo, "staged.txt", "staged v2\n")
    git!(repo, ["add", "staged.txt"])
    write!(repo, "unstaged.txt", "unstaged v2\n")
    write!(repo, "untracked.txt", "untracked\n")
    write!(repo, "ignored.log", "ignored\n")
    repo
  end

  # Everything about the user's git state that BM must leave alone.
  defp user_state(repo) do
    %{
      index: File.read!(Path.join(repo, ".git/index")),
      head: git!(repo, ["rev-parse", "HEAD"]),
      branch: git!(repo, ["symbolic-ref", "HEAD"]),
      cached: git!(repo, ["diff", "--cached"]),
      status: git!(repo, ["status", "--porcelain"]),
      log: git!(repo, ["log", "--oneline", "--exclude=refs/bm/*", "--all"])
    }
  end

  defp tree_files(repo, tree), do: git!(repo, ["ls-tree", "-r", "--name-only", tree])

  describe "snapshot" do
    test "records staged, unstaged and untracked content without touching user state", ctx do
      repo = fixture!(ctx)
      before = user_state(repo)

      assert {:ok, tree} = Git.snapshot(repo)
      assert user_state(repo) == before

      assert tree_files(repo, tree) |> String.split("\n") |> Enum.sort() ==
               ~w(.gitignore staged.txt tracked.txt unstaged.txt untracked.txt)

      assert git!(repo, ["cat-file", "blob", "#{tree}:staged.txt"]) == "staged v2"
      assert git!(repo, ["cat-file", "blob", "#{tree}:unstaged.txt"]) == "unstaged v2"
    end

    test "is stable when nothing changed and changes when a file does", ctx do
      repo = fixture!(ctx)
      {:ok, first} = Git.snapshot(repo)
      assert {:ok, ^first} = Git.snapshot(repo)

      write!(repo, "tracked.txt", "changed\n")
      assert {:ok, second} = Git.snapshot(repo)
      assert second != first
    end

    test "works in a repository without commits", ctx do
      repo = Path.join(ctx.tmp_dir, "empty")
      File.mkdir_p!(repo)
      git!(repo, ["init", "-q"])
      assert Git.head(repo) == nil

      write!(repo, "a.txt", "a\n")
      assert {:ok, tree} = Git.snapshot(repo)
      assert tree_files(repo, tree) == "a.txt"
      assert git!(repo, ["status", "--porcelain"]) == "?? a.txt"
    end

    test "rebuilds a damaged private index", ctx do
      repo = fixture!(ctx)
      {:ok, tree} = Git.snapshot(repo)
      File.write!(Path.join(repo, ".git/bm/index"), "garbage")
      assert {:ok, ^tree} = Git.snapshot(repo)
    end

    test "fails outside a repository" do
      dir = Path.join(System.tmp_dir!(), "bm-norepo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      assert {:error, {:git, "rev-parse", _, _}} = Git.snapshot(dir)
    end

    test "fails in a subdirectory of a repository", ctx do
      repo = fixture!(ctx)
      File.mkdir_p!(Path.join(repo, "sub"))
      assert {:error, {:not_repository_root, _}} = Git.snapshot(Path.join(repo, "sub"))
    end
  end

  describe "diff" do
    test "reports added, modified and deleted paths, including odd names", ctx do
      repo = fixture!(ctx)
      {:ok, before} = Git.snapshot(repo)

      write!(repo, "new dir/with space.txt", "new\n")
      write!(repo, "line\nbreak.txt", "odd\n")
      write!(repo, "tracked.txt", "changed\n")
      File.rm!(Path.join(repo, "untracked.txt"))
      {:ok, after_tree} = Git.snapshot(repo)

      assert {:ok, entries} = Git.diff(repo, before, after_tree)

      assert Enum.sort_by(entries, & &1.path) == [
               %{path: "line\nbreak.txt", status: :added},
               %{path: "new dir/with space.txt", status: :added},
               %{path: "tracked.txt", status: :modified},
               %{path: "untracked.txt", status: :deleted}
             ]
    end

    test "is empty between equal trees", ctx do
      repo = fixture!(ctx)
      {:ok, tree} = Git.snapshot(repo)
      assert {:ok, []} = Git.diff(repo, tree, tree)
    end
  end

  describe "baseline" do
    test "user-owned paths are exactly the staged, unstaged and untracked ones", ctx do
      repo = fixture!(ctx)
      before = user_state(repo)

      assert {:ok, %{head: head, tree: tree, user_owned: owned}} = Git.baseline(repo)
      assert owned == ~w(staged.txt unstaged.txt untracked.txt)
      assert head == before.head
      assert {:ok, ^tree} = Git.snapshot(repo)
      assert user_state(repo) == before
    end

    test "a staged change reverted in the working tree is still user-owned", ctx do
      repo = fixture!(ctx)
      write!(repo, "staged.txt", "staged v1\n")
      assert {:ok, %{user_owned: owned}} = Git.baseline(repo)
      assert "staged.txt" in owned
    end
  end

  describe "checkpoint" do
    test "records a tree under refs/bm without touching user state", ctx do
      repo = fixture!(ctx)
      {:ok, tree} = Git.snapshot(repo)
      before = user_state(repo)

      assert {:ok, commit} =
               Git.checkpoint(repo, tree, before.head, "refs/bm/runs/1/1", "checkpoint 1")

      assert user_state(repo) == before
      assert git!(repo, ["rev-parse", "refs/bm/runs/1/1"]) == commit
      assert git!(repo, ["rev-parse", "#{commit}^{tree}"]) == tree
      assert git!(repo, ["rev-parse", "#{commit}^"]) == before.head
      refute git!(repo, ["log", "--oneline", "main"]) =~ "checkpoint 1"
    end

    test "refuses an existing ref and refs outside refs/bm", ctx do
      repo = fixture!(ctx)
      {:ok, tree} = Git.snapshot(repo)
      {:ok, _} = Git.checkpoint(repo, tree, nil, "refs/bm/runs/1/1", "one")

      assert {:error, {:git, "update-ref", _, _}} =
               Git.checkpoint(repo, tree, nil, "refs/bm/runs/1/1", "again")

      assert {:error, {:not_a_bm_ref, "refs/heads/main"}} =
               Git.checkpoint(repo, tree, nil, "refs/heads/main", "no")
    end

    test "works without the user's git identity or with signing configured", ctx do
      repo = fixture!(ctx)
      git!(repo, ["config", "commit.gpgSign", "true"])
      {:ok, tree} = Git.snapshot(repo)
      assert {:ok, _} = Git.checkpoint(repo, tree, nil, "refs/bm/runs/1/1", "one")
    end
  end

  describe "restore" do
    # An "attempt" that creates, modifies, deletes, and changes a mode and a symlink.
    defp attempt!(repo) do
      File.ln_s!("tracked.txt", Path.join(repo, "link"))
      {:ok, before} = Git.snapshot(repo)

      write!(repo, "created/new.txt", "new\n")
      write!(repo, "tracked.txt", "changed by the attempt\n")
      File.rm!(Path.join(repo, "untracked.txt"))
      File.chmod!(Path.join(repo, "unstaged.txt"), 0o755)
      File.rm!(Path.join(repo, "link"))
      File.ln_s!("staged.txt", Path.join(repo, "link"))

      {:ok, after_tree} = Git.snapshot(repo)
      {:ok, entries} = Git.diff(repo, before, after_tree)
      {before, after_tree, entries}
    end

    test "reverts every kind of change", ctx do
      repo = fixture!(ctx)
      {before, after_tree, entries} = attempt!(repo)
      assert length(entries) == 5

      assert :ok = Git.restore(repo, entries, before, after_tree)
      assert {:ok, ^before} = Git.snapshot(repo)
      refute File.exists?(Path.join(repo, "created"))
      assert read(repo, "untracked.txt") == {:ok, "untracked\n"}
      assert File.read_link(Path.join(repo, "link")) == {:ok, "tracked.txt"}
      assert Bitwise.band(File.stat!(Path.join(repo, "unstaged.txt")).mode, 0o111) == 0
    end

    test "accepts write sets as stored in Postgres (string keys)", ctx do
      repo = fixture!(ctx)
      {before, after_tree, entries} = attempt!(repo)
      stored = Enum.map(entries, &%{"path" => &1.path, "status" => to_string(&1.status)})

      assert :ok = Git.restore(repo, stored, before, after_tree)
      assert {:ok, ^before} = Git.snapshot(repo)
    end

    test "refuses and changes nothing when a file changed since", ctx do
      repo = fixture!(ctx)
      {before, after_tree, entries} = attempt!(repo)
      write!(repo, "tracked.txt", "the user's later edit\n")
      {:ok, edited} = Git.snapshot(repo)

      assert {:error, {:changed_since, ["tracked.txt"]}} =
               Git.restore(repo, entries, before, after_tree)

      assert {:ok, ^edited} = Git.snapshot(repo)
      assert read(repo, "tracked.txt") == {:ok, "the user's later edit\n"}
    end

    test "reverts a file that the attempt turned into a directory, and back", ctx do
      repo = fixture!(ctx)
      {:ok, before} = Git.snapshot(repo)
      File.rm!(Path.join(repo, "tracked.txt"))
      write!(repo, "tracked.txt/inner.txt", "now a directory\n")
      File.rm!(Path.join(repo, "untracked.txt"))
      write!(repo, "untracked.txt/deep/x.txt", "x\n")
      {:ok, after_tree} = Git.snapshot(repo)
      {:ok, entries} = Git.diff(repo, before, after_tree)

      assert :ok = Git.restore(repo, entries, before, after_tree)
      assert {:ok, ^before} = Git.snapshot(repo)
      assert read(repo, "tracked.txt") == {:ok, "tracked\n"}

      # The other direction: revert from the directory state back to it.
      {:ok, entries} = Git.diff(repo, after_tree, before)
      assert :ok = Git.restore(repo, entries, after_tree, before)
      assert {:ok, ^after_tree} = Git.snapshot(repo)
    end

    test "refuses to replace a directory that holds files the attempt didn't write", ctx do
      repo = fixture!(ctx)
      {:ok, before} = Git.snapshot(repo)
      File.rm!(Path.join(repo, "tracked.txt"))
      write!(repo, "tracked.txt/inner.txt", "attempt\n")
      {:ok, after_tree} = Git.snapshot(repo)
      {:ok, entries} = Git.diff(repo, before, after_tree)
      write!(repo, "tracked.txt/user.txt", "the user's new file\n")

      assert {:error, {:changed_since, ["tracked.txt"]}} =
               Git.restore(repo, entries, before, after_tree)

      assert read(repo, "tracked.txt/user.txt") == {:ok, "the user's new file\n"}
      assert read(repo, "tracked.txt/inner.txt") == {:ok, "attempt\n"}
    end

    test "never writes through a symlink the attempt put in place of a directory", ctx do
      repo = fixture!(ctx)
      write!(repo, "dir/f.txt", "in dir\n")
      {:ok, before} = Git.snapshot(repo)
      outside = Path.join(ctx.tmp_dir, "outside")
      File.mkdir_p!(outside)
      File.rm_rf!(Path.join(repo, "dir"))
      File.ln_s!(outside, Path.join(repo, "dir"))
      {:ok, after_tree} = Git.snapshot(repo)
      {:ok, entries} = Git.diff(repo, before, after_tree)

      assert :ok = Git.restore(repo, entries, before, after_tree)
      assert File.ls!(outside) == []
      assert read(repo, "dir/f.txt") == {:ok, "in dir\n"}
    end

    test "an edit that lands during the restore is never overwritten", ctx do
      repo = fixture!(ctx)
      {before, after_tree, entries} = attempt!(repo)

      # The attempt deleted untracked.txt; the revert recreates it. The user saves a new
      # untracked.txt after the checks passed, while the restore is running.
      racing_edit = fn -> write!(repo, "untracked.txt", "the user's racing edit\n") end

      assert {:error, {:changed_since, ["untracked.txt"]}} =
               Git.restore(repo, entries, before, after_tree, after_move: racing_edit)

      assert read(repo, "untracked.txt") == {:ok, "the user's racing edit\n"}

      # Everything else is exactly as the attempt left it, and no stash is left behind.
      File.rm!(Path.join(repo, "untracked.txt"))
      assert {:ok, ^after_tree} = Git.snapshot(repo)
      assert Path.wildcard(Path.join(repo, ".git/bm/restore-*")) == []
    end

    test "a file saved at a moved path during the restore is kept, BM's copy is stashed", ctx do
      repo = fixture!(ctx)
      {before, after_tree, entries} = attempt!(repo)

      # tracked.txt is moved aside; the user saves the path again before BM writes it back.
      racing_edit = fn -> write!(repo, "tracked.txt", "the user's racing edit\n") end

      assert {:error, {:interrupted, {:changed_since, ["tracked.txt"]}, stash: stash}} =
               Git.restore(repo, entries, before, after_tree, after_move: racing_edit)

      assert read(repo, "tracked.txt") == {:ok, "the user's racing edit\n"}
      assert [kept] = File.ls!(stash)
      assert File.read!(Path.join(stash, kept)) == "changed by the attempt\n"
    end

    test "a file recreated after the attempt deleted it counts as changed", ctx do
      repo = fixture!(ctx)
      {before, after_tree, entries} = attempt!(repo)
      write!(repo, "untracked.txt", "recreated\n")

      assert {:error, {:changed_since, ["untracked.txt"]}} =
               Git.restore(repo, entries, before, after_tree)
    end
  end

  @tag :perf
  test "snapshots of this repository are fast after the first" do
    repo = File.cwd!()
    {first_us, {:ok, tree}} = :timer.tc(fn -> Git.snapshot(repo) end)
    {second_us, {:ok, ^tree}} = :timer.tc(fn -> Git.snapshot(repo) end)

    IO.puts(
      "\n[perf] snapshot of #{repo}: first #{div(first_us, 1000)} ms, second #{div(second_us, 1000)} ms"
    )

    assert second_us < 1_000_000
  end
end
