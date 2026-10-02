defmodule Bm.Runs.Workspace do
  @moduledoc "A checkout BM works in, identified by its canonical path."

  use Ecto.Schema
  import Ecto.Changeset

  schema "workspaces" do
    field :path, :string

    # Run after every mutating attempt; its success is what "verified" means (e.g. `mix precommit`).
    field :verify_command, :string
    field :settings, :map, default: %{}

    has_many :runs, Bm.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:path, :verify_command, :settings])
    |> validate_required([:path])
    |> validate_change(:path, fn :path, path ->
      if Path.type(path) == :absolute, do: [], else: [path: "must be absolute"]
    end)
    |> validate_length(:path, max: 4_096, count: :codepoints)
    |> validate_length(:verify_command, max: 2_000, count: :codepoints)
    |> unique_constraint(:path)
  end
end
