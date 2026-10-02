defmodule Bm.Bridge.Request do
  @moduledoc "A persisted authoritative request from a BM pi extension and its outcome."

  use Ecto.Schema
  import Ecto.Changeset

  schema "bridge_requests" do
    field :request_id, :string
    field :agent_id, :string
    field :role, :string
    field :op, :string
    field :session_epoch, :integer
    # The attempt assigned to the agent when the request arrived (nil for planners).
    belongs_to :attempt, Bm.Runs.Attempt
    field :payload, :map
    field :outcome, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @fields ~w(request_id agent_id role op session_epoch payload outcome)a

  def changeset(request, attrs) do
    request
    |> cast(attrs, @fields)
    # The attempt is BM's own record of who asked, not part of the request.
    |> change(Map.take(Map.new(attrs), [:attempt_id]))
    |> validate_required(@fields)
    |> unique_constraint(:request_id)
  end
end
