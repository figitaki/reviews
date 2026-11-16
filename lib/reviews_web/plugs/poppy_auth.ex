defmodule ReviewsWeb.Plugs.PoppyAuth do
  @moduledoc """
  Authenticates Poppy API requests (`/api/poppy/v1/*`) with
  `Reviews.Poppy.Adapter` and maps failures to the spec's errors (section 7).

  Options:

    * `:scope` - a scope the request needs. Without an access token the
      response is a 401 challenge naming it; with a token that lacks it, 403
      `insufficient_scope`.

  Assigns `:poppy` (the adapter result) and `:attribution`. Signed in, it also
  assigns `:current_identity` and `:current_user` (the identity's owner), the
  same assigns `RequireApiToken` sets, so API controllers work unchanged.
  """
  import Plug.Conn

  alias Reviews.Poppy

  def init(opts), do: Keyword.take(opts, [:scope])

  def call(conn, opts) do
    request = %{
      method: conn.method,
      # htu is checked against the configured public origin, never the Host
      # header this server received (guides, "Verifying the Session header").
      url: Poppy.issuer() <> conn.request_path,
      headers:
        Map.new(~w(poppy-session poppy-version authorization), fn name ->
          {name, conn |> get_req_header(name) |> List.first()}
        end)
    }

    case Poppy.Adapter.authenticate(request) do
      {:ok, result} -> authorize(conn, result, opts[:scope])
      {:error, reason} -> reject(conn, reason)
    end
  end

  defp authorize(conn, %{identity: nil}, scope) when is_binary(scope) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer scope="#{scope}"))
    |> send_json(401, %{error: "unauthorized", error_description: "Sign in to do this."})
  end

  defp authorize(conn, %{scopes: scopes} = result, scope) do
    if is_nil(scope) or scope in scopes do
      conn
      |> assign(:poppy, result)
      |> assign(:attribution, result.attribution)
      |> assign_signed_in(result)
    else
      conn
      |> put_resp_header(
        "www-authenticate",
        ~s(Bearer error="insufficient_scope", scope="#{scope}")
      )
      |> send_json(403, %{error: "insufficient_scope"})
    end
  end

  defp assign_signed_in(conn, %{identity: nil}), do: conn

  defp assign_signed_in(conn, result) do
    conn
    |> assign(:current_identity, result.identity)
    |> assign(:current_user, result.owner)
  end

  defp reject(conn, :invalid_token) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer error="invalid_token"))
    |> send_json(401, %{error: "invalid_token"})
  end

  defp reject(conn, :version_unsupported),
    do: send_json(conn, 400, %{error: "version_unsupported"})

  defp reject(conn, :session_ended), do: send_json(conn, 400, %{error: "session_ended"})

  # Every other failure is the same error, without the reason (spec 5.3).
  defp reject(conn, _reason), do: send_json(conn, 400, %{error: "invalid_session"})

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, JSON.encode!(body))
    |> halt()
  end
end
