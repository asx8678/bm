defmodule Bm.Plans.Plan do
  @moduledoc """
  A plan made in the chat (plan 31): a draft with a goal, what the model found in the code, and
  its tasks. It changes while it is discussed; running it later copies its tasks into a goal run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:drafting, :ready, :archived]

  schema "plans" do
    belongs_to :workspace, Bm.Runs.Workspace
    field :title, :string
    field :goal, :string
    field :findings, :string
    # In scope, out of scope and assumptions, settled with the user (plan 34).
    field :scope, :string
    field :status, Ecto.Enum, values: @statuses, default: :drafting
    belongs_to :run, Bm.Runs.Run

    has_many :tasks, Bm.Plans.Task, preload_order: [asc: :position]
    # Filled by `Bm.Plans.list_plans/2`.
    field :task_count, :integer, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @doc "A new plan; `workspace_id` is set by the caller, not cast."
  def create_changeset(plan, attrs) do
    plan
    |> cast(attrs, [:title, :goal, :findings])
    |> validate_required([:title, :goal])
    |> validate_length(:title, max: 200, count: :codepoints)
  end

  @doc "Changes the model or the user may make to a plan."
  def update_changeset(plan, attrs) do
    plan
    |> cast(attrs, [:title, :goal, :findings, :scope])
    |> validate_required([:title, :goal])
    |> validate_length(:title, max: 200, count: :codepoints)
  end
end
