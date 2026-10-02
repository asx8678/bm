defmodule BmWeb.Plugs.LocalOnly do
  @moduledoc """
  Refuses requests that don't come from this machine (plan 14.2). BM's JSON API has no
  authentication; the dev endpoint binds 127.0.0.1, but production binds every interface, so
  the API checks the peer address itself.

  A loopback peer is not enough: a web page open in the user's browser also connects from this
  machine, and a form-encoded POST needs no CORS preflight. So requests a browser marks as
  cross-site are refused, and requests with a body must be `application/json` (a cross-origin
  page can only send that after a preflight BM never answers). The CLI sends JSON.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{remote_ip: ip} = conn, _opts) do
    cond do
      not loopback?(ip) ->
        refuse(conn, "BM's API only answers requests from this machine.")

      get_req_header(conn, "sec-fetch-site") |> Enum.any?(&(&1 not in ["same-origin", "none"])) ->
        refuse(conn, "BM's API does not answer requests from web pages.")

      conn.method not in ["GET", "HEAD"] and not json?(conn) ->
        refuse(conn, "BM's API only accepts application/json.")

      true ->
        conn
    end
  end

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] -> type |> String.downcase() |> String.starts_with?("application/json")
      [] -> false
    end
  end

  defp refuse(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Phoenix.json_library().encode!(%{error: message}))
    |> halt()
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65535, 32512, _}), do: true
  defp loopback?(_ip), do: false
end
