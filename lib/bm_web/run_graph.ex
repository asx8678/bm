defmodule BmWeb.RunGraph do
  @moduledoc """
  The canvas of a goal run (Svelte Flow, `FlowCanvas` hook): the planner at the top, one node
  per task key (its latest revision), edges from each dependency to the task that needs it and
  from the planner to the tasks without dependencies. Laid out left to right: the planner, then
  one column per dependency depth (the canvas is wide and short). Live details (the worker's current tool and tokens, the planner's state) are merged
  into nodes with `task_live/2` and `planner_live/1`.
  """

  @column 280
  @row 120

  @doc "Node id of a task key."
  def task_node(key), do: "task-" <> key

  def planner_node, do: "planner"

  @doc "The graph for `run` with its latest `tasks`; `live` maps node ids to extra node data."
  def build(run, tasks, live \\ %{}) do
    depths = depths(tasks)
    columns = tasks |> Enum.group_by(&depths[&1.key]) |> Enum.sort()
    tallest = columns |> Enum.map(fn {_depth, col} -> length(col) end) |> Enum.max(fn -> 1 end)

    task_nodes =
      for {depth, col} <- columns, {task, index} <- Enum.with_index(col) do
        offset = (tallest - length(col)) * @row / 2

        %{
          id: task_node(task.key),
          type: "task",
          position: %{x: (depth + 1) * @column, y: offset + index * @row},
          data: Map.merge(task_data(task), Map.get(live, task_node(task.key), %{}))
        }
      end

    planner_live = Map.get(live, planner_node(), %{})

    # A paused or ended run's planner is not running, whatever its last pi event said.
    planner_live =
      if run.status == :active, do: planner_live, else: Map.drop(planner_live, [:status, :tool])

    planner = %{
      id: planner_node(),
      type: "agent",
      position: %{x: 0, y: (tallest - 1) * @row / 2},
      data: Map.merge(planner_data(run), planner_live)
    }

    keys = MapSet.new(tasks, & &1.key)

    edges =
      Enum.flat_map(tasks, fn task ->
        case Enum.filter(task.depends_on, &MapSet.member?(keys, &1)) do
          [] ->
            [edge(planner_node(), task_node(task.key))]

          deps ->
            Enum.map(deps, &edge(task_node(&1), task_node(task.key)))
        end
      end)

    %{nodes: [planner | task_nodes], edges: edges}
  end

  defp edge(source, target),
    do: %{id: "#{source}->#{target}", source: source, target: target, animated: false}

  defp task_data(task) do
    %{
      label: task.title,
      key: task.key,
      status: task.status,
      revision: task.revision,
      writes: task.writes
    }
  end

  # The planner node reuses the chat page's agent node (status, model, tool, tokens), with its
  # handles on the sides for this left-to-right layout.
  defp planner_data(run) do
    status =
      case run.status do
        :active -> :idle
        :paused -> :paused
        _ended -> :finished
      end

    %{
      label: "Planner",
      status: status,
      model: model_name(),
      tool: nil,
      usage: nil,
      horizontal: true
    }
  end

  defp model_name do
    case Application.get_env(:bm, Bm.Pi.Profile, [])[:model] do
      model when is_binary(model) -> model |> String.split("/") |> List.last()
      _ -> nil
    end
  end

  @doc "Live data for a task node from its worker's pi summary and activity."
  def task_live(summary, activity \\ nil) do
    %{
      tool: summary[:tool],
      last_tool: activity && activity.last,
      calls: (activity && activity.calls) || 0,
      usage: summary[:usage]
    }
  end

  @doc "Live data for the planner node from its pi summary."
  def planner_live(summary) do
    %{
      status: summary[:status],
      model: summary[:model],
      tool: summary[:tool],
      usage: summary[:usage]
    }
  end

  # Depth of each key: 0 without dependencies, else one more than its deepest dependency.
  defp depths(tasks) do
    by_key = Map.new(tasks, &{&1.key, &1})

    Enum.reduce(tasks, %{}, fn task, acc ->
      depth(task.key, by_key, acc, MapSet.new()) |> elem(1)
    end)
  end

  defp depth(key, by_key, acc, seen) do
    cond do
      Map.has_key?(acc, key) ->
        {acc[key], acc}

      not Map.has_key?(by_key, key) or MapSet.member?(seen, key) ->
        {-1, acc}

      true ->
        {deepest, acc} =
          Enum.reduce(by_key[key].depends_on, {-1, acc}, fn dep, {deepest, acc} ->
            {d, acc} = depth(dep, by_key, acc, MapSet.put(seen, key))
            {max(deepest, d), acc}
          end)

        {deepest + 1, Map.put(acc, key, deepest + 1)}
    end
  end
end
