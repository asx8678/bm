defmodule BmWeb.RunComponentsTest do
  use ExUnit.Case, async: true

  alias BmWeb.RunComponents

  test "relative times read naturally" do
    now = ~U[2026-09-29 12:00:00Z]
    at = fn seconds -> DateTime.add(now, -seconds, :second) end

    assert RunComponents.relative(at.(10), now) == "just now"
    assert RunComponents.relative(at.(60), now) == "1 min ago"
    assert RunComponents.relative(at.(600), now) == "10 min ago"
    assert RunComponents.relative(at.(3_600), now) == "1 h ago"
    assert RunComponents.relative(at.(7_200), now) == "2 h ago"
    assert RunComponents.relative(at.(100_000), now) == "yesterday"
    assert RunComponents.relative(at.(5 * 86_400), now) == "5 days ago"
    assert RunComponents.relative(at.(60 * 86_400), now) == "31 Jul 2026"
  end

  test "durations are short" do
    from = ~U[2026-09-29 12:00:00Z]
    assert RunComponents.duration(from, DateTime.add(from, 4)) == "4 s"
    assert RunComponents.duration(from, DateTime.add(from, 125)) == "2 min 5 s"
    assert RunComponents.duration(from, DateTime.add(from, 3_780)) == "1 h 3 min"
    assert RunComponents.duration(from, nil) == nil
  end
end
