defmodule Bm.Repo.Migrations.AddRevertedAtToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      # When the user reverted the whole run's changes (plan 11.4).
      add :reverted_at, :utc_datetime_usec
    end
  end
end
