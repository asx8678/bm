defmodule Bm.Plans do
  @moduledoc """
  Plans made in the chat (plan 31): drafts with tasks, created and changed by the chat model's
  tools (plan 32) and by the user on the plan board (plan 33). Nothing here runs anything.

  Checks: a task key is unique in its plan; dependencies name tasks of the same plan and make no
  cycle; a task others depend on can't be removed; files are relative paths inside the checkout.
  Every change is broadcast on `topic(plan_id)` and `"plans"`:
  `{:plan, plan_id, :plan | {:task, key} | {:removed, key}}`.
  """

  import Ecto.Query

  alias Bm.Plans.{Plan, Task}
  alias Bm.Repo
  alias Bm.Runs.Workspace

  def topic(plan_id), do: "plan:#{plan_id}"

  def subscribe(plan_id), do: Phoenix.PubSub.subscribe(Bm.PubSub, topic(plan_id))
  def subscribe_list, do: Phoenix.PubSub.subscribe(Bm.PubSub, "plans")

  ## Plans

  @doc "Starts a plan for the checkout of `workspace`."
  def create_plan(%Workspace{id: workspace_id}, attrs) do
    %Plan{workspace_id: workspace_id}
    |> Plan.create_changeset(Map.new(attrs))
    |> Repo.insert()
    |> broadcast(:plan)
  end

  def update_plan(%Plan{} = plan, attrs) do
    plan |> Plan.update_changeset(Map.new(attrs)) |> Repo.update() |> broadcast(:plan)
  end

  @doc "A plan with its workspace and its tasks in order."
  def get_plan!(id), do: Plan |> Repo.get!(id) |> Repo.preload([:workspace, tasks: tasks_query()])

  @doc "The most recently changed plans, with their workspaces."
  def list_plans(limit \\ 30) do
    Repo.all(
      from p in Plan,
        where: p.status != :archived,
        order_by: [desc: p.updated_at, desc: p.id],
        limit: ^limit,
        preload: :workspace
    )
  end

  def list_tasks(%Plan{id: plan_id}), do: Repo.all(where(tasks_query(), plan_id: ^plan_id))

  defp tasks_query, do: from(t in Task, order_by: [asc: t.position, asc: t.id])

  ## Tasks

  @doc """
  Adds a task at the end of `plan` (or before the task `before`, a key). `attrs` use the content
  fields of `Bm.Plans.Task` plus `key`.
  """
  def add_task(%Plan{} = plan, attrs, before \\ nil) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    tasks = list_tasks(plan)

    with :ok <- check_files(plan, attrs["files"]),
         :ok <- check_dependencies(tasks, attrs["key"], attrs["depends_on"] || []) do
      Repo.transaction(fn ->
        position = insert_position(plan, tasks, before)

        %Task{plan_id: plan.id, position: position}
        |> Task.create_changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, task} -> task
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> touch(plan)
      |> broadcast_task(plan)
    end
  end

  @doc "Changes task `key` of `plan`; its revision goes up by one."
  def update_task(%Plan{} = plan, key, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    tasks = list_tasks(plan)

    with %Task{} = task <- Enum.find(tasks, &(&1.key == key)) || {:error, :no_such_task},
         :ok <- check_files(plan, attrs["files"]),
         :ok <- check_dependencies(tasks, key, attrs["depends_on"] || task.depends_on) do
      task
      |> Task.update_changeset(attrs)
      |> Repo.update()
      |> touch(plan)
      |> broadcast_task(plan)
    end
  end

  @doc "Removes task `key`; refused while another task depends on it."
  def remove_task(%Plan{} = plan, key) do
    tasks = list_tasks(plan)

    case Enum.find(tasks, &(&1.key == key)) do
      nil ->
        {:error, :no_such_task}

      task ->
        case for(t <- tasks, key in t.depends_on, do: t.key) do
          [] ->
            {:ok, _} = Repo.delete(task)
            touch({:ok, task}, plan)
            broadcast_plan_event(plan.id, {:removed, key})
            {:ok, task}

          dependents ->
            {:error, {:dependents, dependents}}
        end
    end
  end

  @doc "Puts the tasks of `plan` in the order of `keys` (every key once)."
  def reorder_tasks(%Plan{} = plan, keys) do
    tasks = list_tasks(plan)

    if Enum.sort(keys) == Enum.sort(Enum.map(tasks, & &1.key)) do
      Repo.transaction(fn ->
        for {key, position} <- Enum.with_index(keys, 1) do
          from(t in Task, where: t.plan_id == ^plan.id and t.key == ^key)
          |> Repo.update_all(set: [position: position, updated_at: DateTime.utc_now()])
        end
      end)

      touch({:ok, plan}, plan)
      broadcast_plan_event(plan.id, :plan)
      :ok
    else
      {:error, :keys_do_not_match}
    end
  end

  ## Checks

  # Files are relative paths that stay inside the checkout.
  defp check_files(_plan, nil), do: :ok

  defp check_files(_plan, files) when is_list(files) do
    case Enum.reject(files, &relative_inside?/1) do
      [] -> :ok
      bad -> {:error, {:bad_files, bad}}
    end
  end

  defp check_files(_plan, _files), do: {:error, {:bad_files, :not_a_list}}

  defp relative_inside?(path) when is_binary(path) do
    path != "" and Path.type(path) == :relative and
      not Enum.any?(Path.split(path), &(&1 == ".."))
  end

  defp relative_inside?(_path), do: false

  # Every dependency names another task of the plan, and the graph stays acyclic.
  defp check_dependencies(_tasks, _key, deps) when not is_list(deps),
    do: {:error, {:bad_dependencies, :not_a_list}}

  defp check_dependencies(tasks, key, deps) do
    known = MapSet.new(tasks, & &1.key)

    cond do
      key in deps ->
        {:error, {:bad_dependencies, [key]}}

      (unknown = Enum.reject(deps, &MapSet.member?(known, &1))) != [] ->
        {:error, {:unknown_dependencies, unknown}}

      cycle?(tasks, key, deps) ->
        {:error, :dependency_cycle}

      true ->
        :ok
    end
  end

  # With `key` depending on `deps`, can `key` be reached again from one of them?
  defp cycle?(tasks, key, deps) do
    edges = tasks |> Map.new(&{&1.key, &1.depends_on}) |> Map.put(key, deps)
    reaches?(edges, deps, key, MapSet.new())
  end

  defp reaches?(_edges, [], _target, _seen), do: false

  defp reaches?(edges, [node | rest], target, seen) do
    cond do
      node == target -> true
      MapSet.member?(seen, node) -> reaches?(edges, rest, target, seen)
      true -> reaches?(edges, Map.get(edges, node, []) ++ rest, target, MapSet.put(seen, node))
    end
  end

  ## Helpers

  defp insert_position(plan, tasks, nil), do: next_position(plan, tasks)

  defp insert_position(plan, tasks, before) do
    case Enum.find(tasks, &(&1.key == before)) do
      nil ->
        next_position(plan, tasks)

      %{position: position} ->
        from(t in Task, where: t.plan_id == ^plan.id and t.position >= ^position)
        |> Repo.update_all(inc: [position: 1])

        position
    end
  end

  defp next_position(_plan, tasks),
    do: (tasks |> Enum.map(& &1.position) |> Enum.max(fn -> 0 end)) + 1

  # The plan's updated_at follows its tasks, so the plans list orders by activity.
  defp touch({:ok, _} = result, %Plan{id: id}) do
    from(p in Plan, where: p.id == ^id) |> Repo.update_all(set: [updated_at: DateTime.utc_now()])
    result
  end

  defp touch(error, _plan), do: error

  defp broadcast({:ok, %Plan{id: id}} = result, event) do
    broadcast_plan_event(id, event)
    result
  end

  defp broadcast(error, _event), do: error

  defp broadcast_task({:ok, %Task{key: key}} = result, %Plan{id: id}) do
    broadcast_plan_event(id, {:task, key})
    result
  end

  defp broadcast_task(error, _plan), do: error

  defp broadcast_plan_event(plan_id, event) do
    Phoenix.PubSub.broadcast(Bm.PubSub, topic(plan_id), {:plan, plan_id, event})
    Phoenix.PubSub.broadcast(Bm.PubSub, "plans", {:plan, plan_id, event})
  end
end
