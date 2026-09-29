defmodule BmWeb.RunComponents do
  @moduledoc "Components for runs and attempts: status badges and diffs."

  use Phoenix.Component

  # Amber marks activity or a decision to make; sage is accepted; coral is failed.
  @attempt_labels %{
    queued: {"Queued", :muted},
    admitted: {"Starting", :active},
    running: {"Running", :active},
    result_received: {"Finishing", :active},
    settling: {"Finishing", :active},
    verifying: {"Verifying", :active},
    accepted: {"Accepted", :ok},
    held: {"Needs your decision", :decide},
    failed: {"Failed", :bad},
    cancelled: {"Cancelled", :muted},
    needs_reconciliation: {"Interrupted", :decide},
    reverted: {"Reverted", :muted}
  }

  @run_labels %{
    active: {"Active", :active_quiet},
    paused: {"Paused", :decide},
    done: {"Done", :ok},
    failed: {"Failed", :bad},
    cancelled: {"Cancelled", :muted}
  }

  attr :status, :atom, required: true
  attr :rest, :global

  def attempt_status(assigns) do
    {label, tone} = Map.get(@attempt_labels, assigns.status, {to_string(assigns.status), :muted})
    assigns = assign(assigns, label: label, tone: tone)

    ~H"""
    <span class={badge_class(@tone)} {@rest}>
      <span class={dot_class(@tone)}></span>{@label}
    </span>
    """
  end

  attr :status, :atom, required: true
  attr :rest, :global

  def run_status(assigns) do
    {label, tone} = Map.get(@run_labels, assigns.status, {to_string(assigns.status), :muted})
    assigns = assign(assigns, label: label, tone: tone)

    ~H"""
    <span class={badge_class(@tone)} {@rest}>
      <span class={dot_class(@tone)}></span>{@label}
    </span>
    """
  end

  defp badge_class(tone) do
    [
      "inline-flex flex-none items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11px] font-medium",
      case tone do
        :ok -> "border-bm-idle/40 text-bm-idle"
        :bad -> "border-bm-error/40 text-bm-error"
        :decide -> "border-bm-run/50 bg-bm-run/10 text-bm-run"
        :active -> "border-bm-run/40 text-bm-run"
        :active_quiet -> "border-bm-line text-bm-text"
        :muted -> "border-bm-line text-bm-muted"
      end
    ]
  end

  defp dot_class(tone) do
    [
      "size-1.5 rounded-full",
      case tone do
        :ok -> "bg-bm-idle"
        :bad -> "bg-bm-error"
        :decide -> "bg-bm-run"
        :active -> "bg-bm-run animate-pulse motion-reduce:animate-none"
        :active_quiet -> "bg-bm-idle"
        :muted -> "bg-bm-muted"
      end
    ]
  end

  attr :text, :string, required: true, doc: "unified diff of one file"

  @doc "A unified diff with added and removed lines coloured; git's header lines are left out."
  def diff(assigns) do
    assigns = assign(assigns, :lines, diff_lines(assigns.text))

    ~H"""
    <pre class="overflow-x-auto bg-bm-bg py-1.5 font-mono text-[11px] leading-[1.55]" phx-no-format><code><span
      :for={{kind, line} <- @lines}
      class={["block px-3", line_class(kind)]}
    >{line}</span></code></pre>
    """
  end

  @doc false
  def diff_lines(text) do
    text
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@")))
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "\\ No newline")))
    |> Enum.map(fn
      "@@" <> _ = line -> {:hunk, line}
      "+" <> _ = line -> {:add, line}
      "-" <> _ = line -> {:del, line}
      line -> {:ctx, line}
    end)
  end

  defp line_class(:hunk), do: "text-bm-muted"
  defp line_class(:add), do: "bg-bm-idle/12 text-bm-idle"
  defp line_class(:del), do: "bg-bm-error/10 text-bm-error"
  defp line_class(:ctx), do: "text-bm-text/80"
end
