defmodule Bm.Repo.Migrations.AddPlanner do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Optional command run after the workspace verify command; both must pass (plan 7.7).
      add :check, :text
    end

    alter table(:runs) do
      # Planner bookkeeping for goal runs (plan 7.3): session, waves, summary, log, process
      # groups. Nil for single-task runs.
      add :planner, :map
      # Why a run is paused, failed or cancelled, in words.
      add :status_reason, :text
    end

    # A finished task revision waiting to be told to the planner (plan 7.6): received when it
    # ended, delivered when the planner was sent the follow_up that reports it.
    create table(:deliveries) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :delivered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:deliveries, [:task_id])
    create index(:deliveries, [:run_id])
  end
end
