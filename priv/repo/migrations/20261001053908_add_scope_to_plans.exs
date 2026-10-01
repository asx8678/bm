defmodule Bm.Repo.Migrations.AddScopeToPlans do
  use Ecto.Migration

  # The scope of work the chat model settled with the user (plan 34): in scope, out of scope,
  # assumptions.
  def change do
    alter table(:plans) do
      add :scope, :text
    end
  end
end
