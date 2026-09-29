# Live tests drive the real pi and model (costs money). Run with: mix test --only live
ExUnit.start(exclude: [:live])
Ecto.Adapters.SQL.Sandbox.mode(Bm.Repo, :manual)
