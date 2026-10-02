defmodule Bm.Repo.Migrations.WidenFreeTextColumns do
  use Ecto.Migration

  # Text from users and models was stored in varchar(255): a longer verify command, check,
  # title or path raised in the coordinator, the planner or the chat and crashed it (plan 36.9).
  # Lengths are checked by the changesets instead.
  def change do
    alter table(:workspaces) do
      modify :path, :text, from: :string
      modify :verify_command, :text, from: :string
    end

    alter table(:tasks) do
      modify :title, :text, from: :string
      modify :writes, {:array, :text}, from: {:array, :string}
    end

    alter table(:plans) do
      modify :title, :text, from: :string
    end

    alter table(:plan_tasks) do
      modify :title, :text, from: :string
      modify :check, :text, from: :string
      modify :files, {:array, :text}, from: {:array, :string}
    end

    alter table(:attempts) do
      modify :pgid_file, :text, from: :string
    end
  end
end
