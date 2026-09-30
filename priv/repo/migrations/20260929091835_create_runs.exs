defmodule Bm.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:workspaces) do
      add :path, :string, null: false
      add :verify_command, :string
      add :settings, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspaces, [:path])

    create table(:runs) do
      add :workspace_id, references(:workspaces, on_delete: :restrict), null: false
      add :goal, :text, null: false
      add :status, :string, null: false
      add :plan_open, :boolean, null: false, default: false
      add :budget_usd, :float
      add :spent_usd, :float, null: false, default: 0.0
      add :spent_unknown, :integer, null: false, default: 0
      add :baseline, :map
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:workspace_id])

    # The run lock: at most one unfinished run per workspace (decision D4).
    create unique_index(:runs, [:workspace_id],
             where: "status IN ('active', 'paused')",
             name: :runs_one_unfinished_per_workspace
           )

    create table(:tasks) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :revision, :integer, null: false, default: 1
      add :title, :string, null: false
      add :goal, :text, null: false
      add :done_when, :text
      add :mutates, :boolean, null: false
      add :writes, {:array, :string}, null: false, default: []
      add :depends_on, {:array, :string}, null: false, default: []
      add :status, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tasks, [:run_id, :key, :revision])

    create table(:attempts) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :role, :string, null: false
      add :status, :string, null: false
      add :agent_id, :string
      add :session_epoch, :integer
      add :pgid, :integer
      add :pgid_file, :string
      add :tree_before, :string
      add :tree_after, :string
      add :actual_writes, {:array, :map}, null: false, default: []
      add :flags, {:array, :string}, null: false, default: []
      add :result, :map
      add :verify, :map
      add :checkpoint_ref, :string
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:attempts, [:task_id, :number])
    create index(:attempts, [:status])
  end
end
