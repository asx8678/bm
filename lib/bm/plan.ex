defmodule Bm.Plan do
  @moduledoc """
  Validates a planner's `propose_task` proposal before BM accepts it (plan step 7.1,
  docs/ARCHITECTURE.md §6). Pure: the caller passes the run's state in `ctx`.

  A proposal is accepted only if:

    * planning is open and the run's budget is not spent;
    * `key`, `title`, `goal` and `mutates` are present and well formed; `done_when`, `writes`,
      `depends_on` and `check` are optional and well typed;
    * the key is new in the run, or it names a task whose only revision failed, was blocked or
      was cancelled: that is the one allowed **re-plan**, stored as revision 2;
    * every dependency is an existing task that has not failed, been blocked or cancelled, and
      the graph stays acyclic;
    * a mutating task declares a non-empty write set (kept required after plan step 6.6.4: the
      model declared it exactly in 11 of 11 benchmark runs), and a read-only task declares none;
    * every declared path lies inside the workspace, outside `.git`, and is not a file with the
      user's uncommitted changes.

  Errors are sentences the planner model can act on.
  """

  alias Bm.Runs.Task

  @key_format ~r/^[a-z][a-z0-9_]{0,59}$/
  @max_title 200
  @max_check 2_000
  @ended [:failed, :blocked, :cancelled]

  @type ctx :: %{
          tasks: [Task.t()],
          user_owned: [String.t()],
          root: Path.t(),
          budget_left: float() | nil,
          plan_open: boolean()
        }

  @doc "Returns `{:ok, task_attrs}` for `Bm.Runs.create_task/2`, or `{:error, reason}`."
  def validate(proposal, ctx) when is_map(proposal) do
    latest = latest_by_key(ctx.tasks)

    with :ok <- check_open(ctx),
         {:ok, fields} <- fields(proposal),
         :ok <- check_policy(fields.check, ctx.root, ctx.user_owned),
         {:ok, revision} <- check_key(fields.key, latest),
         {:ok, depends_on} <- check_dependencies(fields, latest),
         {:ok, writes} <- check_writes(fields, ctx) do
      {:ok, %{fields | depends_on: depends_on, writes: writes} |> Map.put(:revision, revision)}
    end
  end

  def validate(_proposal, _ctx), do: {:error, "The proposal must be an object."}

  @doc "The latest revision of every key among `tasks`."
  def latest_by_key(tasks) do
    tasks
    |> Enum.group_by(& &1.key)
    |> Map.new(fn {key, revisions} -> {key, Enum.max_by(revisions, & &1.revision)} end)
  end

  @doc """
  A cycle in `graph` (key => keys it depends on) as a list of keys, or nil. Dependencies on
  unknown keys are ignored.
  """
  def cycle(graph) do
    Enum.find_value(Map.keys(graph), fn key -> visit(key, graph, [], MapSet.new()) end)
  end

  defp visit(key, graph, path, seen) do
    cond do
      key in path ->
        Enum.reverse([key | path]) |> Enum.drop_while(&(&1 != key))

      MapSet.member?(seen, key) or not Map.has_key?(graph, key) ->
        nil

      true ->
        Enum.find_value(Map.fetch!(graph, key), fn dep ->
          visit(dep, graph, [key | path], MapSet.put(seen, key))
        end)
    end
  end

  ## Rules

  defp check_open(%{plan_open: false}),
    do: {:error, "The plan is closed; BM accepts tasks only while planning is open."}

  defp check_open(%{budget_left: left}) when is_number(left) and left <= 0,
    do: {:error, "The run's budget is spent; BM accepts no more tasks."}

  defp check_open(_ctx), do: :ok

  defp fields(p) do
    with {:ok, key} <- string(p, "key", required: true),
         {:ok, title} <- string(p, "title", required: true, max: @max_title),
         {:ok, goal} <- string(p, "goal", required: true),
         {:ok, done_when} <- string(p, "done_when"),
         {:ok, check} <- string(p, "check", max: @max_check),
         :ok <- check_command(check),
         {:ok, mutates} <- boolean(p, "mutates"),
         {:ok, writes} <- strings(p, "writes"),
         {:ok, depends_on} <- strings(p, "depends_on") do
      {:ok,
       %{
         key: key,
         title: title,
         goal: goal,
         done_when: done_when,
         check: check,
         mutates: mutates,
         writes: writes,
         depends_on: depends_on
       }}
    end
  end

  defp string(p, field, opts \\ []) do
    case Map.get(p, field) do
      nil ->
        if opts[:required], do: {:error, "`#{field}` is required."}, else: {:ok, nil}

      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          value == "" and opts[:required] ->
            {:error, "`#{field}` must not be empty."}

          value == "" ->
            {:ok, nil}

          # Code points, as the database counts them (a grapheme can be several).
          opts[:max] && length(String.codepoints(value)) > opts[:max] ->
            {:error, "`#{field}` is too long (at most #{opts[:max]} characters)."}

          true ->
            {:ok, value}
        end

      _other ->
        {:error, "`#{field}` must be a string."}
    end
  end

  # A check with JSON-style escaped quotes (`\"`) reaches the shell literally and fails whatever
  # the worker does (seen live in plan 9.4); ask for plain shell instead.
  defp check_command(check) when is_binary(check) do
    if String.contains?(check, ~S(\")),
      do:
        {:error,
         "`check` contains escaped quotes (a backslash before a double quote); write it " <>
           ~S[as plain shell, e.g. test "$(python3 wc.py f)" = "3 3"]},
      else: :ok
  end

  defp check_command(_check), do: :ok

  @doc """
  A task's `check` runs as a shell command in the workspace, without pi and its guard, so it is
  held to the rules of the planner's own bash (read-only `Bm.Policy`, plan 36.4). `:ok` or
  `{:error, sentence}`.
  """
  def check_policy(nil, _root, _user_owned), do: :ok

  def check_policy(check, root, user_owned) when is_binary(check) do
    ctx = %{root: root, user_owned: user_owned || [], mode: :read_only}

    case Bm.Policy.authorize("bash", %{"command" => check}, ctx) do
      :allow -> :ok
      {:deny, reason} -> {:error, "`check` is refused: #{reason} A check must only read and run."}
    end
  end

  defp boolean(p, field) do
    case Map.get(p, field) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:error, "`#{field}` is required (true or false)."}
      _other -> {:error, "`#{field}` must be true or false."}
    end
  end

  defp strings(p, field) do
    case Map.get(p, field) do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        cond do
          not Enum.all?(list, &is_binary/1) ->
            {:error, "`#{field}` must be a list of strings."}

          length(list) > 200 or Enum.any?(list, &(String.length(&1) > 1_000)) ->
            {:error, "`#{field}` is too long (at most 200 entries of 1000 characters)."}

          true ->
            {:ok, list |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()}
        end

      _other ->
        {:error, "`#{field}` must be a list of strings."}
    end
  end

  defp check_key(key, latest) do
    cond do
      not Regex.match?(@key_format, key) ->
        {:error,
         "Key #{inspect(key)} is not valid: use lowercase letters, digits and underscores, " <>
           "starting with a letter (at most 60 characters)."}

      not Map.has_key?(latest, key) ->
        {:ok, 1}

      latest[key].status in @ended and latest[key].revision == 1 ->
        {:ok, 2}

      latest[key].status in @ended ->
        {:error, "Task #{key} was already re-planned once; BM does not accept it again."}

      true ->
        {:error, "Key #{key} is already used in this run; choose a new key."}
    end
  end

  defp check_dependencies(%{key: key, depends_on: deps}, latest) do
    graph =
      latest
      |> Map.new(fn {k, task} -> {k, task.depends_on} end)
      |> Map.put(key, deps)

    cond do
      key in deps ->
        {:error, "Task #{key} can't depend on itself."}

      missing = Enum.find(deps, &(not Map.has_key?(latest, &1))) ->
        {:error,
         "depends_on names #{missing}, which is not a task in this run. Propose #{missing} " <>
           "first, then the tasks that depend on it."}

      ended = Enum.find(deps, &(latest[&1].status in @ended)) ->
        {:error,
         "Task #{ended} #{latest[ended].status}; a new task can't depend on it. Re-propose " <>
           "#{ended} first (allowed once) or plan without it."}

      cycle = cycle(graph) ->
        {:error, "These dependencies form a cycle: #{Enum.join(cycle, " -> ")}."}

      true ->
        {:ok, deps}
    end
  end

  defp check_writes(%{mutates: true, writes: []}, _ctx),
    do: {:error, "A task that changes files (mutates: true) must list them in `writes`."}

  defp check_writes(%{mutates: false, writes: [_ | _]}, _ctx),
    do: {:error, "A read-only task (mutates: false) must not declare `writes`."}

  defp check_writes(%{writes: writes}, ctx) do
    root = Path.expand(ctx.root)

    Enum.reduce_while(writes, {:ok, []}, fn path, {:ok, acc} ->
      full = Path.expand(path, root)
      relative = Path.relative_to(full, root)

      cond do
        full == root or not String.starts_with?(full, root <> "/") ->
          {:halt, {:error, "#{path} is outside the workspace; only declare files inside it."}}

        relative == ".git" or String.starts_with?(relative, ".git/") ->
          {:halt, {:error, "#{path} is inside .git; BM manages git itself."}}

        Bm.Policy.user_owned_path?(relative, ctx.user_owned) ->
          {:halt,
           {:error,
            "#{relative} has the user's uncommitted changes; BM won't change it. Plan " <>
              "without changing it, or say in close_plan that the goal needs it."}}

        true ->
          {:cont, {:ok, acc ++ [relative]}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.uniq(list)}
      error -> error
    end
  end
end
