defmodule Bm.Repo.Migrations.AddCommitToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      # The commit the user made of the run's accepted changes (plan 15.1, D26).
      add :commit_sha, :string
    end
  end
end
