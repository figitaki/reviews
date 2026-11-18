defmodule ReviewsWeb.OAuthController do
  @moduledoc """
  The Reviews OAuth issuer (`Reviews.OAuth`) over HTTP. Gatekeep checks the
  requests and issues the tokens; this controller owns what people see and
  how Reviews answers.

    * `GET /oauth/authorize` - `Gatekeep.Plug.Authorize` checks the request
      and hands it to this module, the issuer's `Gatekeep.Consent`: the owner
      signs in with GitHub, chooses which of their agent identities the app
      acts as, and approves scopes.
    * `POST /oauth/authorize` - the owner's decision (`approve/2`).
    * `POST /oauth/token` - `authorization_code` with PKCE and
      `refresh_token`. Clients with keys authenticate with a
      `private_key_jwt` client assertion; public clients send `client_id`
      and no assertion and rely on PKCE. A `DPoP` proof binds the tokens to
      its key (Poppy spec 4.5).
    * `POST /oauth/revoke` - RFC 7009 revocation.
    * `POST /oauth/register` - dynamic client registration (RFC 7591) for
      clients that don't use a client metadata document.

  Never log request bodies here: they hold codes, tokens, and assertions.
  """
  use ReviewsWeb, :controller

  @behaviour Gatekeep.Consent

  alias Gatekeep.{Authorization, Registration, TokenEndpoint}
  alias Reviews.Accounts
  alias Reviews.OAuth

  def authorize(conn, _params), do: Gatekeep.Plug.Authorize.call(conn, OAuth)

  @impl Gatekeep.Consent
  def handle_authorization(conn, request), do: render_consent(conn, request)

  # Errors that must not redirect: an unusable client or redirect URI, or a
  # bad request from a registered client, since anyone can register any
  # redirect URI (OAuth 2.1 §7.12.2).
  @impl Gatekeep.Consent
  def handle_error(conn, reason), do: invalid_request(conn, :bad_request, reason)

  def approve(conn, %{"decision" => decision} = params) do
    user = conn.assigns.current_user
    config = OAuth.config()

    case {user, Authorization.check(config, params)} do
      {nil, _} ->
        invalid_request(conn, :unauthorized, :signed_out, "Sign in first")

      {_user, {:ok, request}} when decision == "approve" ->
        granted = Enum.filter(request.scopes, &(&1 in List.wrap(params["granted_scopes"])))

        case OAuth.approve(user, params["identity_id"], request, granted) do
          {:ok, url} ->
            Gatekeep.Plug.Authorize.redirect(conn, url)

          {:error, :invalid_identity} ->
            conn
            |> put_flash(
              :error,
              "Choose one of your agent identities and at least one permission."
            )
            |> render_consent(request)
        end

      {_user, {:ok, request}} ->
        Gatekeep.Plug.Authorize.redirect(conn, Authorization.deny(config, request))

      {_user, {:redirect, url}} ->
        Gatekeep.Plug.Authorize.redirect(conn, url)

      {_user, {:error, reason}} ->
        handle_error(conn, reason)
    end
  end

  defp render_consent(conn, request) do
    case conn.assigns.current_user do
      nil ->
        render(conn, :sign_in,
          request: request,
          return_to: current_path(conn),
          page_title: "Sign in to connect an agent"
        )

      user ->
        render(conn, :consent,
          request: request,
          auth_params: request.params,
          identities: Accounts.list_agent_identities_for(user),
          scopes: request.scope_descriptions,
          current_user: user,
          page_title: "Connect an agent"
        )
    end
  end

  defp invalid_request(conn, status, reason, title \\ "Sign-in link not valid") do
    conn
    |> put_status(status)
    |> render(:invalid_request, reason: reason, page_title: title)
  end

  def token(conn, params) do
    case TokenEndpoint.token(OAuth.config(), params, http(conn)) do
      {:ok, body} -> conn |> no_store() |> json(body)
      {:error, :invalid_client} -> oauth_error(conn, 401, :invalid_client)
      {:error, error} -> oauth_error(conn, 400, error)
    end
  end

  def revoke(conn, params) do
    case TokenEndpoint.revoke(OAuth.config(), params, http(conn)) do
      :ok -> conn |> no_store() |> send_resp(200, "")
      {:error, :invalid_client} -> oauth_error(conn, 401, :invalid_client)
    end
  end

  # Every `DPoP` header value. Reviews issues no client secrets, so the
  # `Authorization` header isn't client authentication here: a public client
  # that also sends Basic credentials authenticates by its `client_id`.
  defp http(conn), do: %{authorization: nil, dpop: get_req_header(conn, "dpop")}

  def register(conn, params) do
    case Registration.register(OAuth.config(), params) do
      {:ok, body} ->
        conn |> no_store() |> put_status(:created) |> json(body)

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, error, description} ->
        conn
        |> no_store()
        |> put_status(:bad_request)
        |> json(%{error: error, error_description: description})
    end
  end

  defp oauth_error(conn, status, error) do
    conn
    |> no_store()
    |> put_status(status)
    |> json(%{error: to_string(error)})
  end

  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
