defmodule Bm.Runs.Run do
  @moduledoc """
  One goal worked on in one workspace. At most one run per workspace is unfinished (`:active` or
  `:paused`); a partial unique index enforces it (decision D4).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @unfinished [:active, :paused]
  @finished [:done, :failed, :cancelled]

  schema "runs" do
    belongs_to :workspace, Bm.Runs.Workspace
    field :goal, :string
    field :status, Ecto.Enum, values: @unfinished ++ @finished, default: :active
    field :plan_open, :boolean, default: false
    field :budget_usd, :float
    # Confirmed spend, and how many usage entries came without a cost (never counted as 0).
    field :spent_usd, :float, default: 0.0
    field :spent_unknown, :integer, default: 0
    # HEAD, snapshot tree and user-owned paths at run start (see Bm.Workspace.Git, phase 3).
    field :baseline, :map
    # The verify command's result on the checkout before the first attempt (6.6.3):
    # "exit", "output", "timeout", and "changed" (files it changed).
    field :baseline_verify, :map
    field :finished_at, :utc_datetime_usec

    has_many :tasks, Bm.Runs.Task

    timestamps(type: :utc_datetime_usec)
  end

  def unfinished_statuses, do: @unfinished
  def finished_statuses, do: @finished

  @doc "Changeset for a new run; `workspace_id` is set by the caller, not cast."
  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [:goal, :plan_open, :budget_usd, :baseline])
    |> validate_required([:goal])
    |> validate_number(:budget_usd, greater_than: 0)
    |> unique_constraint(:workspace_id, name: :runs_one_unfinished_per_workspace)
  end

  def status_changeset(run, status) when status in @finished do
    change(run, status: status, finished_at: DateTime.utc_now())
  end

  def status_changeset(run, status) when status in @unfinished, do: change(run, status: status)
end
