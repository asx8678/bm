defmodule Bm.Pi.Profile do
  @moduledoc """
  Controlled pi profiles for BM-managed agents, and the check that runs before an agent may
  receive work.

  | Role | Extensions | Tools |
  |---|---|---|
  | `:planner` | zro, bm_planner, bm_guard | read-only + `bash` (read-only policy) + `propose_plan`, `propose_task`, `close_plan` |
  | `:reader` | zro, bm_worker, bm_guard | read-only + `bash` (read-only policy) + `submit_result` |
  | `:writer` | zro, bm_worker, bm_guard | + `edit`, `write`, `bash` |

  Workers are **Fabric-free** (decision D16): live qualification showed that `--tools` does not
  bind Fabric's nested `pi.*` calls and that Fabric starts the user's MCP servers. Without
  Fabric, pi's `--tools` allowlist and `bm_guard` fully cover the worker's tools.

  Every profile starts pi with `--no-extensions`, an explicit `-e` list, a `--tools` allowlist and
  a pinned model. `start/3` starts the agent and fails closed unless its self-reported active tools,
  model and pinned versions match the profile.

  Configuration (`config :bm, Bm.Pi.Profile`): `:pi_command` (default `["pi"]`), `:model`,
  `:zro_extension`, `:fabric_extension`, `:pi_version` and `:fabric_version` (nil skips a
  version check).
  """

  @read_tools ~w(read grep find ls)
  @mutating_tools ~w(edit write bash)

  @roles %{
    # Planner and reader run commands too (tests, git log, builds), with the guard asking the
    # BEAM in read-only policy mode; the snapshot after the session catches what the policy
    # cannot (plan step 6.6.5).
    planner: %{
      fabric?: false,
      extensions: ~w(bm_planner bm_guard),
      tools: @read_tools ++ ~w(bash propose_plan propose_task close_plan),
      required: ~w(bash propose_plan propose_task close_plan),
      reports: ~w(profile guard)
    },
    reader: %{
      fabric?: false,
      extensions: ~w(bm_worker bm_guard),
      tools: @read_tools ++ ~w(bash submit_result ask_planner),
      required: ~w(bash submit_result ask_planner),
      reports: ~w(profile guard)
    },
    # The chat (plan 32): read-only like the planner, with tools that make and change a plan
    # (Bm.Plans) and standing instructions (priv/pi/prompts/chat.md).
    chat: %{
      fabric?: false,
      extensions: ~w(bm_chat bm_guard),
      tools:
        @read_tools ++
          ~w(bash create_plan update_plan add_task update_task remove_task get_plan ask_user),
      required:
        ~w(bash create_plan update_plan add_task update_task remove_task get_plan ask_user),
      reports: ~w(profile guard),
      system_prompt: "chat.md"
    },
    writer: %{
      fabric?: false,
      extensions: ~w(bm_worker bm_guard),
      tools: @read_tools ++ @mutating_tools ++ ~w(submit_result ask_planner),
      required: ~w(submit_result ask_planner edit write bash),
      reports: ~w(profile guard)
    }
  }

  @start_timeout 30_000

  def roles, do: Map.keys(@roles)

  @doc "Command, environment and expectations for `role`."
  def build(role) when is_map_key(@roles, role) do
    spec = @roles[role]
    config = config()

    extension_paths =
      [config[:zro_extension]] ++
        if(spec.fabric?, do: [config[:fabric_extension]], else: []) ++
        Enum.map(spec.extensions, &Path.join(extensions_dir(), "#{&1}.ts"))

    command =
      Keyword.get(config, :pi_command, ["pi"]) ++
        ~w(--mode rpc --no-session --no-extensions) ++
        Enum.flat_map(Enum.reject(extension_paths, &is_nil/1), &["-e", &1]) ++
        ["--tools", Enum.join(spec.tools, ","), "--model", config[:model]] ++
        case spec[:system_prompt] do
          nil -> []
          file -> ["--append-system-prompt", Path.join(prompts_dir(), file)]
        end

    # Fabric's own agent spawning must be off through configuration (agents.maxDepth); this
    # internal variable is only an additional guard.
    env = if spec.fabric?, do: %{"PI_FABRIC_DEPTH" => "99"}, else: %{}

    # Read-only sessions probe code with one-off `python3 -c`; without this Python writes
    # __pycache__/ into repositories that don't ignore it, which counts as a change (plan 19.2).
    env =
      if "edit" in spec.tools, do: env, else: Map.put(env, "PYTHONDONTWRITEBYTECODE", "1")

    %{role: role, command: command, env: env, spec: spec}
  end

  @doc """
  Starts agent `id` with the `role` profile and checks it. Returns `{:ok, report}` or
  `{:error, reason}`; on error the agent is stopped. `opts` are passed to `Bm.Pi.ensure_agent/2`
  (for example `:owner` and `:cwd`).
  """
  def start(id, role, opts \\ []) do
    with :ok <- check_versions() do
      profile = build(role)
      Bm.Pi.subscribe(id)

      result =
        with {:ok, _pid} <-
               Bm.Pi.ensure_agent(
                 id,
                 Keyword.merge(opts,
                   command: profile.command,
                   env: profile.env,
                   shutdown_command: "/bm-shutdown"
                 )
               ) do
          id |> await_reports(profile.spec.reports) |> verify(profile)
        end

      Bm.Pi.unsubscribe(id)
      if match?({:error, _}, result), do: Bm.Pi.stop(id)
      result
    end
  end

  @doc "Checks the self-reports and state of a started agent against its profile."
  def verify({:error, _} = error, _profile), do: error

  def verify({:ok, %{model: model, reports: reports}}, profile) do
    active = MapSet.new(get_in(reports, ["profile", "tools"]) || [])
    allowed = MapSet.new(profile.spec.tools)
    expected_model = config()[:model] |> String.split("/") |> List.last()

    cond do
      missing = Enum.reject(profile.spec.required, &MapSet.member?(active, &1)) |> nonempty() ->
        {:error, {:missing_tools, missing}}

      extra = active |> MapSet.difference(allowed) |> MapSet.to_list() |> nonempty() ->
        {:error, {:unexpected_tools, extra}}

      model_mismatch?(model, expected_model) ->
        {:error, {:model_mismatch, model}}

      true ->
        {:ok, %{role: profile.role, model: model, tools: MapSet.to_list(active)}}
    end
  end

  @doc "Compares installed pi and Fabric versions with the pinned ones."
  def check_versions do
    config = config()

    with :ok <- check(:pi, config[:pi_version], &pi_version/0),
         :ok <- check(:fabric, config[:fabric_version], fn -> fabric_version(config) end) do
      :ok
    end
  end

  defp check(_name, nil, _actual), do: :ok

  defp check(name, pinned, actual) do
    case actual.() do
      ^pinned -> :ok
      other -> {:error, {:version_mismatch, name, pinned: pinned, installed: other}}
    end
  end

  defp pi_version do
    [exe | args] = Keyword.get(config(), :pi_command, ["pi"])

    case System.cmd(exe, args ++ ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp fabric_version(config) do
    with path when is_binary(path) <- config[:fabric_extension],
         {:ok, json} <- File.read(Path.join(path, "package.json")),
         {:ok, %{"version" => version}} <- JSON.decode(json) do
      version
    else
      _ -> nil
    end
  end

  # Waits until the agent is idle and every expected self-report has arrived.
  defp await_reports(id, expected) do
    deadline = System.monotonic_time(:millisecond) + @start_timeout
    do_await(id, expected, %{model: nil, idle?: false, reports: %{}}, deadline)
  end

  defp do_await(id, expected, acc, deadline) do
    if acc.idle? and Enum.all?(expected, &Map.has_key?(acc.reports, &1)) do
      {:ok, acc}
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:pi, ^id, {:bridge, event, data}, _} ->
          do_await(id, expected, put_in(acc.reports[event], data), deadline)

        {:pi, ^id, _event, %{status: :idle, model: model}} ->
          do_await(id, expected, %{acc | idle?: true, model: model}, deadline)

        {:pi, ^id, {:error, message}, _} ->
          {:error, {:start_failed, message}}

        {:pi, ^id, _event, _summary} ->
          do_await(id, expected, acc, deadline)
      after
        remaining ->
          {:error, {:no_report, expected -- Map.keys(acc.reports)}}
      end
    end
  end

  defp model_mismatch?(nil, _expected), do: true
  defp model_mismatch?(model, expected), do: String.downcase(model) != String.downcase(expected)

  defp nonempty([]), do: nil
  defp nonempty(list), do: list

  defp extensions_dir, do: Application.app_dir(:bm, "priv/pi/extensions")
  defp prompts_dir, do: Application.app_dir(:bm, "priv/pi/prompts")
  defp config, do: Application.get_env(:bm, __MODULE__, [])
end
