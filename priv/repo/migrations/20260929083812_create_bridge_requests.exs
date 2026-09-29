defmodule Bm.Repo.Migrations.CreateBridgeRequests do
  use Ecto.Migration

  def change do
    create table(:bridge_requests) do
      add :request_id, :string, null: false
      add :agent_id, :string, null: false
      add :role, :string, null: false
      add :op, :string, null: false
      add :session_epoch, :integer, null: false
      add :payload, :map, null: false
      add :outcome, :map, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:bridge_requests, [:request_id])
  end
end
