defmodule Bm.Repo.Migrations.CreatePlans do
  use Ecto.Migration

  # Plans made in the chat (plan 31): drafts that hold tasks, separate from runs and tasks.
  def change do
    create table(:plans) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false
      add :title, :string, null: false
      add :goal, :text, null: false
      # What the model found in the code before planning.
      add :findings, :text
      add :status, :string, null: false, default: "drafting"
      # The goal run the plan became, once it is run (later phases).
      add :run_id, references(:runs, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:plans, [:workspace_id])

    create table(:plan_tasks) do
      add :plan_id, references(:plans, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :position, :integer, null: false
      add :revision, :integer, null: false, default: 1
      add :title, :string, null: false
      add :why, :text
      add :existing, :text
      add :approach, :text
      add :files, {:array, :string}, null: false, default: []
      add :done_when, :text
      add :depends_on, {:array, :string}, null: false, default: []
      add :risks, :text
      add :open_questions, {:array, :text}, null: false, default: []
      add :check, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plan_tasks, [:plan_id, :key])
    create index(:plan_tasks, [:plan_id, :position])
  end
end
