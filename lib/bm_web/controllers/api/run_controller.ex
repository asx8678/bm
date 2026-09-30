defmodule BmWeb.Api.RunController do
  @moduledoc """
  BM's local JSON API (plan 14.2), used by the `mix bm.*` terminal client. Goals start through
  the running server's workspace coordinator, the same path as the Tasks page, so the web page
  shows them live.

    * `POST /api/goals` — `repo`, `goal`, optional `verify_command`, `budget_usd` → the run
    * `GET /api/runs` — recent runs (`limit`, default 20)
    * `GET /api/runs/:id` — one run with its tasks and their latest attempts
    * `POST /api/runs/:id/commit` — commit the run's accepted changes (plan 15.1, D26)
    * `POST /api/runs/:id/keep`, `/revert`, `/cancel` — the run page's Keep, Revert and Stop,
      for the workspace's current run (plan 24.2)
    * `POST /api/runs/:id/approvals/:dialog_id` — answer a worker's pending approval with
      `confirmed`, `value` or `cancelled` (plan 24.1)
  """

  use BmWeb, :controller

  alias Bm.Runs
  alias Bm.Workspace.Coordinator

  def create_goal(conn, params) do
    path = String.trim(params["repo"] || "")
    goal = String.trim(params["goal"] || "")

    budget =
      case params["budget_usd"] do
        n when is_number(n) and n > 0 -> n * 1.0
        text when is_binary(text) -> parse_budget(text)
        _ -> nil
      end

    attrs = %{
      goal: goal,
      verify_command: blank_to_nil(params["verify_command"]),
      budget_usd: budget
    }

    with :ok <- if(goal == "", do: {:error, :no_goal}, else: :ok),
         {:ok, _pid} <- Coordinator.ensure_started(path),
         {:ok, run} <- Coordinator.start_goal(path, attrs) do
      run = Runs.get_run_with_workspace(run.id)

      conn
      |> put_status(:created)
      |> json(run_summary(conn, run))
    else
      {:error, reason} ->
        {field, message} = BmWeb.HomeLive.explain(reason, path)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message, field: field})
    end
  end

  def index(conn, params) do
    limit =
      case Integer.parse(to_string(params["limit"] || "20")) do
        {n, ""} when n in 1..200 -> n
        _ -> 20
      end

    {runs, _more?} = Runs.search_runs(params["q"] || "", nil, limit)
    json(conn, %{runs: Enum.map(runs, &run_summary(conn, &1))})
  end

  def show(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(String.replace_prefix(id, "BM-", "")),
         %{} = run <- Runs.get_run_with_workspace(id) do
      tasks =
        for task <- Runs.latest_tasks(run) do
          attempt = Runs.latest_attempt(task)

          %{
            key: task.key,
            title: task.title,
            revision: task.revision,
            status: task.status,
            depends_on: task.depends_on,
            attempt:
              attempt &&
                %{
                  status: attempt.status,
                  error: attempt.error,
                  review: attempt.verify && get_in(attempt.verify, ["review", "verdict"]),
                  files: Enum.map(attempt.actual_writes, & &1["path"])
                }
          }
        end

      approvals = approvals(run)

      json(
        conn,
        Map.merge(run_summary(conn, run), %{
          plan_open: run.plan_open,
          # An attempt left changes that wait for the user's Keep or Revert (plan 16.2), or
          # the worker waits for an approval (plan 24.1).
          waiting_for_you:
            run.status in [:active, :paused] and
              (approvals != [] or
                 Enum.any?(
                   tasks,
                   &(&1.attempt && &1.attempt.status in [:held, :needs_reconciliation])
                 )),
          approvals: approvals,
          summary: run.planner && run.planner["summary"],
          tasks: tasks
        })
      )
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "No such run."})
    end
  end

  def commit(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(String.replace_prefix(id, "BM-", "")),
         %{} = run <- Runs.get_run_with_workspace(id),
         {:ok, _pid} <- Coordinator.ensure_started(run.workspace.path) do
      case Coordinator.commit_run(run.workspace.path, run.id) do
        {:ok, run} ->
          summary = run_summary(conn, Runs.get_run_with_workspace(run.id))
          json(conn, Map.put(summary, :commit_sha, run.commit_sha))

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: BmWeb.RunLive.explain_commit(reason)})
      end
    else
      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "No such run."})
    end
  end

  @doc "Keep, Revert or Stop (`action`) in the workspace's current run `id` (plan 24.2)."
  def decide(conn, %{"id" => id, "action" => action}) when action in ~w(keep revert cancel) do
    with_current_run(conn, id, fn path ->
      case action do
        "keep" -> Coordinator.keep(path)
        "revert" -> Coordinator.revert(path)
        "cancel" -> Coordinator.cancel(path)
      end
    end)
  end

  def decide(conn, _params),
    do: conn |> put_status(:not_found) |> json(%{error: "Unknown action."})

  def answer(conn, %{"id" => id, "dialog_id" => dialog_id} = params) do
    reply = Map.take(params, ["confirmed", "value", "cancelled"])
    with_current_run(conn, id, &Coordinator.answer_approval(&1, dialog_id, reply))
  end

  defp with_current_run(conn, id, fun) do
    with {id, ""} <- Integer.parse(String.replace_prefix(id, "BM-", "")),
         %{} = run <- Runs.get_run_with_workspace(id),
         path = run.workspace.path,
         {:ok, _pid} <- Coordinator.ensure_started(path),
         %{run_id: ^id} <- Coordinator.state(path),
         :ok <- fun.(path) do
      show(conn, %{"id" => to_string(id)})
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: BmWeb.RunLive.explain_action(reason)})

      %{run_id: _other} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "This run is not the workspace's unfinished run."})

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "No such run."})
    end
  end

  defp approvals(%{id: id, status: status, workspace: workspace})
       when status in [:active, :paused] do
    case Coordinator.state(workspace.path) do
      %{run_id: ^id, approvals: approvals} ->
        for a <- approvals do
          a.payload
          |> Map.take(~w(method title message options placeholder prefill))
          |> Map.merge(%{"id" => a.id, "timeout_s" => div(a.timeout, 1000), "since" => a.since})
        end

      _ ->
        []
    end
  catch
    :exit, _ -> []
  end

  defp approvals(_run), do: []

  defp run_summary(conn, run) do
    %{
      id: run.id,
      label: BmWeb.RunComponents.label(run),
      status: run.status,
      reason: run.status_reason,
      goal: run.goal,
      repo: run.workspace.path,
      goal_run: run.planner != nil,
      spent_usd: run.spent_usd,
      budget_usd: run.budget_usd,
      url: url(conn, ~p"/runs/#{run.id}")
    }
  end

  defp parse_budget(text) do
    case Float.parse(String.trim(text)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp blank_to_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      value -> value
    end
  end
end
