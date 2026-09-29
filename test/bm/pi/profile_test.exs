defmodule Bm.Pi.ProfileTest do
  use ExUnit.Case, async: true

  alias Bm.Pi.Profile

  defp start(role) do
    id = "profile-#{role}-#{System.unique_integer([:positive])}"
    on_exit(fn -> Bm.Pi.stop(id) end)
    {id, Profile.start(id, role)}
  end

  test "each role builds an explicit, restricted command" do
    planner = Profile.build(:planner)
    assert "--no-extensions" in planner.command
    assert tools(planner) == ~w(read grep find ls bash propose_task close_plan)
    assert planner.env == %{}

    writer = Profile.build(:writer)
    assert ~w(edit write bash submit_result) -- tools(writer) == []
    assert writer.env == %{}
    assert Enum.any?(writer.command, &String.ends_with?(&1, "bm_guard.ts"))
    # Planner and reader run bash too, so they carry the guard (read-only policy, 6.6.5).
    for role <- [:reader, :planner] do
      assert Enum.any?(Profile.build(role).command, &String.ends_with?(&1, "bm_guard.ts"))
      refute "edit" in tools(Profile.build(role))
    end
  end

  test "every role starts and passes its check" do
    for role <- Profile.roles() do
      assert {id, {:ok, %{role: ^role, model: "Fake Model"}}} = start(role)
      assert %{summary: %{status: :idle}} = Bm.Pi.snapshot(id)
    end
  end

  test "a tool outside the profile fails the check" do
    profile = Profile.build(:planner)
    reports = %{"profile" => %{"tools" => ~w(read propose_task close_plan bash edit)}}

    assert {:error, {:unexpected_tools, ["edit"]}} =
             Profile.verify({:ok, %{model: "Fake Model", reports: reports}}, profile)
  end

  test "a missing required tool fails the check" do
    profile = Profile.build(:reader)
    reports = %{"profile" => %{"tools" => ~w(read grep bash)}}

    assert {:error, {:missing_tools, ["submit_result"]}} =
             Profile.verify({:ok, %{model: "Fake Model", reports: reports}}, profile)
  end

  test "a different model fails the check" do
    profile = Profile.build(:reader)
    reports = %{"profile" => %{"tools" => ~w(read bash submit_result)}}

    assert {:error, {:model_mismatch, "Other"}} =
             Profile.verify({:ok, %{model: "Other", reports: reports}}, profile)
  end

  defp tools(%{command: command}) do
    index = Enum.find_index(command, &(&1 == "--tools"))
    command |> Enum.at(index + 1) |> String.split(",")
  end
end
