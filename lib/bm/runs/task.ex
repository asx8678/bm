defmodule Bm.Runs.Task do
  @moduledoc """
  A logical unit of work in a run. Accepted task definitions are immutable: a change is a new
  `revision` with the same `key`. Plan validation (phase 7) runs before a task is created.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:queued, :running, :accepted, :failed, :blocked, :cancelled]

  schema "tasks" do
    belongs_to :run, Bm.Runs.Run
    field :key, :string
    field :revision, :integer, default: 1
    field :title, :string
    field :goal, :string
    field :done_when, :string
    field :mutates, :boolean
    # Declared write set: files the task says it will create or change.
    field :writes, {:array, :string}, default: []
    field :depends_on, {:array, :string}, default: []
    # Optional command run after the workspace verify command; both must pass (plan 7.7).
    field :check, :string
    field :status, Ecto.Enum, values: @statuses, default: :queued

    has_many :attempts, Bm.Runs.Attempt

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @doc "Changeset for a new task; `run_id` is set by the caller, not cast."
  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :key,
      :revision,
      :title,
      :goal,
      :done_when,
      :mutates,
      :writes,
      :depends_on,
      :check
    ])
    |> validate_required([:key, :title, :goal, :mutates])
    |> validate_format(:key, ~r/^[a-z][a-z0-9_]*$/)
    |> validate_length(:title, max: 200, count: :codepoints)
    |> validate_length(:check, max: 2_000, count: :codepoints)
    |> unique_constraint([:run_id, :key, :revision])
  end
end
