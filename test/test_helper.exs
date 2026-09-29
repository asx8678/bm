# Live tests drive the real pi and model (costs money): mix test --only live
# Timing checks against this repository: mix test --only perf
ExUnit.start(exclude: [:live, :perf])
Ecto.Adapters.SQL.Sandbox.mode(Bm.Repo, :manual)
