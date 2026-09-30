defmodule Bm.Runs.Delivery do
  @moduledoc """
  A finished task revision to report to the planner (plan 7.6). Created (received) once per task
  when it ends, whatever reported the end; `delivered_at` is set when the planner was sent the
  follow_up that includes it. The unique index on `task_id` gives duplicate reports one effect.
  """

  use Ecto.Schema

  schema "deliveries" do
    belongs_to :run, Bm.Runs.Run
    belongs_to :task, Bm.Runs.Task
    field :status, Ecto.Enum, values: [:accepted, :failed, :blocked, :cancelled]
    field :delivered_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
