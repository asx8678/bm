defmodule Bm.PolicyTest do
  use ExUnit.Case, async: true

  alias Bm.Policy

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, "mine.txt"), "user's change")
    outside = Path.join(dir, "outside")
    File.mkdir_p!(outside)
    # Symlinks inside the workspace that point out of it.
    File.ln_s!(outside, Path.join(root, "escape"))
    File.ln_s!(Path.join(outside, "f.txt"), Path.join(root, "escape.txt"))

    %{ctx: %{root: root, user_owned: ["mine.txt"]}, root: root}
  end

  describe "edit and write" do
    test "paths are decided after pi's rules and symlinks", %{ctx: ctx, root: root} do
      for {path, expected} <- [
            {"lib/new.ex", :allow},
            {"./lib/../lib/a.ex", :allow},
            {"@lib/at_prefix.ex", :allow},
            {Path.join(root, "lib/abs.ex"), :allow},
            {"new_dir/deep/file.txt", :allow},
            {"../x", :deny},
            {"lib/../../x", :deny},
            {"/etc/x", :deny},
            {"~/x", :deny},
            {"escape/f.txt", :deny},
            {"escape.txt", :deny},
            {".git/config", :deny},
            {"mine.txt", :deny},
            {"lib/../mine.txt", :deny}
          ],
          tool <- ["edit", "write"] do
        assert decision(Policy.authorize(tool, %{"path" => path}, ctx)) == expected,
               "#{tool} #{path}"
      end
    end

    test "a missing path is refused", %{ctx: ctx} do
      assert {:deny, _} = Policy.authorize("write", %{"content" => "x"}, ctx)
    end
  end

  describe "bash" do
    test "commands are decided by what they do", %{ctx: ctx} do
      for {command, expected} <- [
            {"mix test", :allow},
            {"ls -la && cat mix.exs | head", :allow},
            {"git status", :allow},
            {"git diff HEAD~1 -- lib", :allow},
            {"git log --oneline", :allow},
            {"git -C sub status", :allow},
            {"git branch", :allow},
            {"git branch -a", :allow},
            {"git stash list", :allow},
            {"git tag", :allow},
            {"nohup sleep 1 &", :allow},
            {"rm -rf _build/test lib/old", :allow},
            {"rm -f /tmp/scratch.txt", :allow},
            {"echo hi 2>&1", :allow},
            {"git commit -m x", :deny},
            {"git add -A", :deny},
            {"git -C . push", :deny},
            {"git -c user.name=x commit -m y", :deny},
            {"/usr/bin/git reset --hard", :deny},
            {"git checkout -- lib/a.ex", :deny},
            {"git stash", :deny},
            {"git branch feature", :deny},
            {"git branch -D main", :deny},
            {"git tag v1", :deny},
            {"mix test; git commit -am wip", :deny},
            {"echo $(git push)", :deny},
            {"env FOO=1 git commit", :deny},
            {"FOO=1 git add .", :deny},
            {"setsid sleep 100", :deny},
            {"sleep 100 & disown", :deny},
            {"sudo rm x", :deny},
            {"rm -rf /", :deny},
            {"rm -rf ~", :deny},
            {"rm -rf $HOME/x", :deny},
            {"rm -r ../other", :deny},
            {"rm escape/f.txt", :deny},
            {"npm publish", :deny},
            {"mix hex.publish", :deny},
            {"cd lib && gh release create v1", :deny},
            # Files a shell command writes follow the same rules as edit/write.
            {"echo x > lib/a.ex", :allow},
            {"mix test > /tmp/out.log 2>&1", :allow},
            {"cmd >/dev/null 2>&1", :allow},
            {"echo x >> new_file.txt", :allow},
            {"printf 'more\\n' >> mine.txt", :deny},
            {"echo x > mine.txt", :deny},
            {"echo x &> mine.txt", :deny},
            {"echo x > \"mine.txt\"", :deny},
            {"echo x > /etc/passwd", :deny},
            {"echo x > ../outside.txt", :deny},
            {"echo x > $HOME/.bashrc", :deny},
            {"cat a | tee -a mine.txt", :deny},
            {"cat a | tee lib/copy.txt", :allow},
            {"sed -i 's/a/b/' mine.txt", :deny},
            {"sed -i.bak -e 's/a/b/' mine.txt", :deny},
            {"sed -i 's/a/b/' lib/a.ex", :allow},
            {"sed 's/a/b/' mine.txt", :allow},
            {"cp lib/a.ex mine.txt", :deny},
            {"mv mine.txt lib/moved.txt", :deny},
            {"mv lib/a.ex lib/b.ex", :allow},
            {"mv lib/a.ex ../away.ex", :deny},
            {"rm mine.txt", :deny},
            {"echo x > .git/HEAD", :deny}
          ] do
        assert decision(Policy.authorize("bash", %{"command" => command}, ctx)) == expected,
               command
      end
    end

    test "a denial explains itself", %{ctx: ctx} do
      assert {:deny, reason} = Policy.authorize("bash", %{"command" => "git commit -m x"}, ctx)
      assert reason =~ "BM records and checkpoints changes itself"
    end
  end

  test "other tools are refused", %{ctx: ctx} do
    assert {:deny, _} = Policy.authorize("fabric_exec", %{}, ctx)
  end

  defp decision(:allow), do: :allow
  defp decision({:deny, reason}) when is_binary(reason), do: :deny
end
