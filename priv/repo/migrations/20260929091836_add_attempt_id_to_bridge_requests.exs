defmodule Bm.Repo.Migrations.AddAttemptIdToBridgeRequests do
  use Ecto.Migration

  def change do
    alter table(:bridge_requests) do
      # The attempt the BEAM had assigned to the agent when the request arrived (planners: none).
      add :attempt_id, references(:attempts, on_delete: :nilify_all)
    end

    create index(:bridge_requests, [:attempt_id])
  end
end
