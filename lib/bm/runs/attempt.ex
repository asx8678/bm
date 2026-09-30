defmodule Bm.Runs.Attempt do
  @moduledoc """
  One execution of a task by one pi process. Only the BEAM moves an attempt between states, and
  only along `transitions/0`; `Bm.Runs.transition_attempt/3` persists a move.

      queued → admitted → running → result_received → settling → verifying → accepted
                                  ╰────────────────────╯                  ╰→ held
      in flight (admitted … verifying) → failed | cancelled | needs_reconciliation

  A worker's `submit_result` only moves `running → result_received`; it doesn't mean the work is
  settled or verified. `running → settling` covers a worker that stopped without a result.
  `held` waits for the user after a failed verification: Keep (`accepted`) or Revert
  (`reverted`). Failed, cancelled and reconciliation attempts can also be reverted, and so can an
  accepted one, but only if it is the run's latest (checked by the coordinator).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @in_flight [:admitted, :running, :result_received, :settling, :verifying]
  @abort [:failed, :cancelled, :needs_reconciliation]

  @transitions %{
    queued: [:admitted, :cancelled],
    admitted: [:running | @abort],
    running: [:result_received, :settling | @abort],
    result_received: [:settling | @abort],
    settling: [:verifying | @abort],
    verifying: [:accepted, :held | @abort],
    held: [:accepted, :reverted],
    needs_reconciliation: [:accepted, :reverted],
    failed: [:reverted],
    cancelled: [:reverted],
    accepted: [:reverted],
    reverted: []
  }

  @statuses Map.keys(@transitions)

  schema "attempts" do
    belongs_to :task, Bm.Runs.Task
    field :number, :integer
    field :role, Ecto.Enum, values: [:reader, :writer]
    field :status, Ecto.Enum, values: @statuses, default: :queued
    # Identity and fencing: the pi process this attempt runs in.
    field :agent_id, :string
    field :session_epoch, :integer
    # Process groups (decision D18): pi's own, and the file where bm_guard records the others.
    field :pgid, :integer
    field :pgid_file, :string
    field :boot_id, :string
    # Snapshot trees (decision D19) and the resulting write set.
    field :tree_before, :string
    field :tree_after, :string
    field :actual_writes, {:array, :map}, default: []
    field :flags, {:array, :string}, default: []
    field :result, :map
    field :verify, :map
    field :checkpoint_ref, :string
    field :error, :string
    # The worker's tool calls and messages, compacted when its pi session stopped (plan 10.4).
    field :transcript, {:array, :map}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Allowed moves: status => statuses it may move to."
  def transitions, do: @transitions

  def statuses, do: @statuses

  @doc "Statuses in which an attempt may still have a live pi process or be changing files."
  def in_flight_statuses, do: @in_flight

  def allowed?(from, to), do: to in Map.get(@transitions, from, [])

  # Fields a transition may set along with the new status.
  @transition_fields ~w(agent_id session_epoch pgid pgid_file boot_id tree_before tree_after
                        actual_writes flags result verify checkpoint_ref error transcript)a

  @doc "Changeset for a new attempt; `task_id` and `number` are set by the caller."
  def create_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> unique_constraint([:task_id, :number])
  end

  @doc "Changeset setting transition fields without changing the status."
  def fields_changeset(attempt, attrs), do: cast(attempt, attrs, @transition_fields)

  @doc """
  Changeset moving `attempt` to `to` and setting `attrs`. Invalid (with an error on `:status`)
  if the move is not in `transitions/0`.
  """
  def transition_changeset(%__MODULE__{status: from} = attempt, to, attrs \\ %{}) do
    changeset = attempt |> cast(attrs, @transition_fields) |> put_change(:status, to)

    if allowed?(from, to),
      do: changeset,
      else: add_error(changeset, :status, "illegal transition", from: from, to: to)
  end
end
