defmodule BmWeb.Plugs.LocalOnly do
  @moduledoc """
  Refuses requests that don't come from this machine (plan 14.2). BM's JSON API has no
  authentication; the dev endpoint binds 127.0.0.1, but production binds every interface, so
  the API checks the peer address itself.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{remote_ip: ip} = conn, _opts) do
    if loopback?(ip) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, ~s({"error":"BM's API only answers requests from this machine."}))
      |> halt()
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65535, 32512, _}), do: true
  defp loopback?(_ip), do: false
end
