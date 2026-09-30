defmodule Bm.Repo.Migrations.AddBootIdToAttempts do
  use Ecto.Migration

  def change do
    alter table(:attempts) do
      # Boot the process groups were recorded in; recovery ignores groups from an earlier boot.
      add :boot_id, :string
    end
  end
end
