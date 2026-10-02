defmodule BmWeb.Plugs.LocalHost do
  @moduledoc """
  Answers only requests addressed to this machine by name (decision D32). BM has no login: its
  pages can start runs whose verify command runs as a shell command, and its API can commit.
  A page on another site can't read BM's pages, but with DNS rebinding (its own host name made
  to resolve to 127.0.0.1) it becomes same-origin with BM. Such requests still carry the other
  site's host name, so every request whose Host isn't a loopback name (or the endpoint's
  configured host) is refused. The LiveView socket is covered by `check_origin`.
  """

  import Plug.Conn

  @loopback ~w(localhost 127.0.0.1 ::1 [::1])

  def init(opts), do: opts

  def call(conn, _opts) do
    if allowed?(conn.host) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "BM only answers requests addressed to this machine (localhost).")
      |> halt()
    end
  end

  @doc """
  True for loopback names, `*.localhost`, the endpoint's configured host and
  `config :bm, BmWeb.Plugs.LocalHost, extra_hosts: [...]` (the tests' `www.example.com`).
  """
  def allowed?(host) do
    host = String.downcase(host || "")
    extra = Application.get_env(:bm, __MODULE__, [])[:extra_hosts] || []

    host in @loopback or String.ends_with?(host, ".localhost") or
      host == String.downcase(BmWeb.Endpoint.host()) or host in extra
  end
end
