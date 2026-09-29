defmodule BmWeb.RunComponents do
  @moduledoc "Components for runs and attempts: status badges, diffs, time and money."

  use Phoenix.Component

  @doc "A time as `3 min ago`, `2 h ago`, `yesterday` or a date; hover shows the exact time."
  attr :at, :any, required: true
  attr :rest, :global

  def ago(assigns) do
    ~H"""
    <time :if={@at} datetime={DateTime.to_iso8601(@at)} title={exact(@at)} {@rest}>{relative(@at)}</time>
    """
  end

  @doc false
  def relative(%DateTime{} = at, now \\ DateTime.utc_now()) do
    seconds = DateTime.diff(now, at, :second)

    cond do
      seconds < 45 -> "just now"
      seconds < 90 -> "1 min ago"
      seconds < 3_600 -> "#{div(seconds, 60)} min ago"
      seconds < 5_400 -> "1 h ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)} h ago"
      seconds < 172_800 -> "yesterday"
      seconds < 30 * 86_400 -> "#{div(seconds, 86_400)} days ago"
      true -> Calendar.strftime(at, "%-d %b %Y")
    end
  end

  defp exact(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")

  @doc "A duration between two times as `4 s`, `2 min 5 s` or `1 h 3 min`; nil without an end."
  def duration(%DateTime{} = from, %DateTime{} = to) do
    seconds = max(DateTime.diff(to, from, :second), 0)

    cond do
      seconds < 60 -> "#{seconds} s"
      seconds < 3_600 -> "#{div(seconds, 60)} min #{rem(seconds, 60)} s"
      true -> "#{div(seconds, 3_600)} h #{div(rem(seconds, 3_600), 60)} min"
    end
  end

  def duration(_from, _to), do: nil

  @doc "Money in USD with four decimals, the precision of model pricing."
  def money(nil), do: "–"
  def money(amount), do: "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 4)

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
