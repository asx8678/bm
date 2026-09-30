defmodule Bm.Repo.Migrations.AddBaselineVerifyToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      # Result of the verify command on the checkout before the first attempt (plan step 6.6.3).
      add :baseline_verify, :map
    end
  end
end
