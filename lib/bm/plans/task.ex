defmodule Bm.Plans.Task do
  @moduledoc """
  A task of a plan (plan 31), with the content the user wants to read before anything runs:
  why, what already exists in the code, the approach, the files, when it is done, its
  dependencies, risks and open questions. Every change bumps its `revision`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @content [
    :title,
    :why,
    :existing,
    :approach,
    :files,
    :done_when,
    :depends_on,
    :risks,
    :open_questions,
    :check
  ]

  schema "plan_tasks" do
    belongs_to :plan, Bm.Plans.Plan
    field :key, :string
    field :position, :integer
    field :revision, :integer, default: 1
    field :title, :string
    field :why, :string
    field :existing, :string
    field :approach, :string
    field :files, {:array, :string}, default: []
    field :done_when, :string
    field :depends_on, {:array, :string}, default: []
    field :risks, :string
    field :open_questions, {:array, :string}, default: []
    field :check, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The fields a model or the user can write."
  def content_fields, do: @content

  @doc "A new task; `plan_id` and `position` are set by the caller, not cast."
  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [:key | @content])
    |> validate_required([:key, :title])
    |> validate_format(:key, ~r/^[a-z][a-z0-9_]{0,47}$/,
      message: "must be snake_case: lowercase letters, digits and _, starting with a letter"
    )
    |> validate_lengths()
    |> unique_constraint(:key, name: :plan_tasks_plan_id_key_index)
  end

  @doc "A change of content; the revision goes up by one."
  def update_changeset(task, attrs) do
    task
    |> cast(attrs, @content)
    |> validate_required([:title])
    |> validate_lengths()
    |> put_change(:revision, task.revision + 1)
  end

  # Counted in code points, as the database does (plan 36.9).
  defp validate_lengths(changeset) do
    changeset
    |> validate_length(:title, max: 200, count: :codepoints)
    |> validate_length(:check, max: 2_000, count: :codepoints)
    |> validate_change(:files, fn :files, files ->
      if Enum.all?(files, &(String.length(&1) <= 1_000)),
        do: [],
        else: [files: "has a path longer than 1000 characters"]
    end)
  end
end
