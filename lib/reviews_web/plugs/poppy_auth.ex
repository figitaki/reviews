defmodule ReviewsWeb.Plugs.PoppyAuth do
  @moduledoc """
  Authenticates Poppy API requests (`/api/poppy/v1/*`) with the configured
  `Reviews.ExternalIdentity` adapter (`config :reviews, Reviews.Poppy,
  adapter:`, default `Reviews.Poppy.Adapter`) and maps failures to the spec's
  errors (section 7).

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
        |> Map.put("dpop", get_req_header(conn, "dpop"))
    }

    {scheme, _token} = Poppy.Adapter.credentials(request.headers["authorization"])

    adapter = Poppy.config(:adapter, Poppy.Adapter)

    case adapter.authenticate(request, []) do
      {:ok, result} -> authorize(conn, result, opts[:scope], scheme)
      {:error, reason} -> reject(conn, reason, scheme)
    end
  end

  defp authorize(conn, %{identity: nil}, scope, _scheme) when is_binary(scope) do
    conn
    |> put_resp_header("www-authenticate", challenge(nil, scope: scope))
    |> send_json(401, %{error: "unauthorized", error_description: "Sign in to do this."})
  end

  defp authorize(conn, %{scopes: scopes} = result, scope, scheme) do
    if is_nil(scope) or scope in scopes do
      conn
      |> assign(:poppy, result)
      |> assign(:attribution, result.attribution)
      |> assign_signed_in(result)
    else
      conn
      |> put_resp_header(
        "www-authenticate",
        challenge(scheme, error: "insufficient_scope", scope: scope)
      )
      |> send_json(403, %{error: "insufficient_scope"})
    end
  end

  # One challenge per scheme the API accepts (spec 7). Error details go in the
  # challenge of the scheme the request used, and in both when it used none
  # (RFC 9449 §7.2). The DPoP challenge names its algorithms.
  defp challenge(scheme, params) do
    bearer = if scheme in [nil, :bearer], do: params, else: []
    dpop = if scheme in [nil, :dpop], do: params, else: []
    algs = Enum.join(Poppy.dpop_signing_algs(), " ")

    auth_challenge("Bearer", bearer) <> ", " <> auth_challenge("DPoP", dpop ++ [algs: algs])
  end

  defp auth_challenge(name, []), do: name

  defp auth_challenge(name, params),
    do: name <> " " <> Enum.map_join(params, ", ", fn {key, value} -> ~s(#{key}="#{value}") end)

  defp assign_signed_in(conn, %{identity: nil}), do: conn

  defp assign_signed_in(conn, result) do
    conn
    |> assign(:current_identity, result.identity)
    |> assign(:current_user, result.owner)
  end

  defp reject(conn, error, scheme) when error in [:invalid_token, :invalid_dpop_proof] do
    conn
    |> put_resp_header("www-authenticate", challenge(scheme, error: error))
    |> send_json(401, %{error: to_string(error)})
  end

  defp reject(conn, :version_unsupported, _scheme),
    do: send_json(conn, 400, %{error: "version_unsupported"})

  defp reject(conn, :session_ended, _scheme), do: send_json(conn, 400, %{error: "session_ended"})

  # Every other failure is the same error, without the reason (spec 5.3).
  defp reject(conn, _reason, _scheme), do: send_json(conn, 400, %{error: "invalid_session"})

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, JSON.encode!(body))
    |> halt()
  end
end
