defmodule Bm.Repo.Migrations.AddTranscriptToAttempts do
  use Ecto.Migration

  def change do
    alter table(:attempts) do
      # What the worker did, captured when its pi session stops: tool calls and its messages,
      # compacted (plan 10.4).
      add :transcript, {:array, :map}, null: false, default: []
    end
  end
end
