defmodule ReviewsWeb.OAuthController do
  @moduledoc """
  The Reviews OAuth issuer (`Reviews.OAuth`).

    * `GET /oauth/authorize` and `POST /oauth/authorize` - the owner signs in
      with GitHub, chooses which of their agent identities the app acts as,
      and approves scopes.
    * `POST /oauth/token` - `authorization_code` with PKCE and
      `refresh_token`. Clients with keys authenticate with a
      `private_key_jwt` client assertion; public clients send `client_id`
      and no assertion and rely on PKCE. For a resource that takes DPoP, a
      `DPoP` proof binds the tokens to its key (Poppy spec 4.5).
    * `POST /oauth/revoke` - RFC 7009 revocation.
    * `POST /oauth/register` - dynamic client registration (RFC 7591) for
      clients that don't use a client metadata document.

  Never log request bodies here: they hold codes, tokens, and assertions.
  """
  use ReviewsWeb, :controller

  alias Reviews.Accounts
  alias Reviews.OAuth
  alias Reviews.OAuth.{Clients, Registration, Tokens}

  @authorize_params ~w(response_type client_id redirect_uri scope state code_challenge code_challenge_method dpop_jkt resource)

  def authorize(conn, params) do
    case OAuth.check_authorization_request(params) do
      {:ok, request} ->
        render_consent(conn, request, Map.take(params, @authorize_params))

      {:redirect_error, error, request} ->
        redirect_error(conn, request, error)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> render(:invalid_request, reason: reason, page_title: "Sign-in link not valid")
    end
  end

  def approve(conn, %{"decision" => decision} = params) do
    user = conn.assigns.current_user

    case {user, OAuth.check_authorization_request(params)} do
      {nil, _} ->
        conn
        |> put_status(:unauthorized)
        |> render(:invalid_request, reason: :signed_out, page_title: "Sign in first")

      {_user, {:ok, request}} when decision == "approve" ->
        granted = Enum.filter(request.scopes, &(&1 in List.wrap(params["granted_scopes"])))

        case OAuth.approve(user, params["identity_id"], request, granted) do
          {:ok, code} ->
            redirect(conn, external: callback_url(request, code: code))

          {:error, :invalid_identity} ->
            conn
            |> put_flash(
              :error,
              "Choose one of your agent identities and at least one permission."
            )
            |> render_consent(request, Map.take(params, @authorize_params))
        end

      {_user, {:ok, request}} ->
        redirect(conn, external: callback_url(request, error: "access_denied"))

      {_user, {:redirect_error, error, request}} ->
        redirect_error(conn, request, error)

      {_user, {:error, reason}} ->
        conn
        |> put_status(:bad_request)
        |> render(:invalid_request, reason: reason, page_title: "Sign-in link not valid")
    end
  end

  defp render_consent(conn, request, auth_params) do
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
          auth_params: auth_params,
          identities: Accounts.list_agent_identities_for(user),
          scopes: OAuth.scope_descriptions(request.provider),
          current_user: user,
          page_title: "Connect an agent"
        )
    end
  end

  # Anyone can register a client with any redirect URI, so redirecting a
  # registered client's bad request before the owner has seen anything would
  # make this page an open redirector (OAuth 2.1 §7.12.2). Show the error here
  # instead. Clients with a metadata document redirect as usual: their
  # redirect URIs are on the domain that published the document.
  defp redirect_error(conn, %{client: %{registered: true}}, _error) do
    conn
    |> put_status(:bad_request)
    |> render(:invalid_request, reason: :bad_request, page_title: "Sign-in link not valid")
  end

  defp redirect_error(conn, request, error),
    do: redirect(conn, external: callback_url(request, error: error))

  # The redirect back carries `iss` (RFC 9207), including on errors (spec 4.2).
  defp callback_url(request, fields) do
    query =
      fields
      |> Keyword.merge(state: request.state, iss: OAuth.issuer())
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> URI.encode_query()

    uri = URI.parse(request.redirect_uri)
    URI.to_string(%{uri | query: Enum.join(Enum.reject([uri.query, query], &is_nil/1), "&")})
  end

  def token(conn, params) do
    with {:ok, client, method} <- authenticate_client(params),
         {:ok, dpop_jkt} <- dpop_key(conn, client) do
      result =
        case params["grant_type"] do
          "authorization_code" -> OAuth.exchange_code(client.client_id, method, params, dpop_jkt)
          "refresh_token" -> OAuth.refresh(client.client_id, method, params, dpop_jkt)
          _ -> {:error, :unsupported_grant_type}
        end

      case result do
        {:ok, body} -> conn |> no_store() |> json(body)
        {:error, error} -> oauth_error(conn, 400, error)
      end
    else
      {:error, :invalid_client} -> oauth_error(conn, 401, :invalid_client)
      {:error, :invalid_dpop_proof} -> oauth_error(conn, 400, :invalid_dpop_proof)
    end
  end

  # A DPoP proof is optional (Poppy spec 4.5). With one, the issued tokens are
  # bound to its key. It is checked before the grant, so a bad proof doesn't
  # use up the code.
  defp dpop_key(conn, client) do
    case get_req_header(conn, "dpop") do
      [] ->
        {:ok, nil}

      proofs ->
        request = %{
          method: conn.method,
          url: OAuth.issuer() <> conn.request_path,
          client_id: client.client_id
        }

        case Reviews.Poppy.Tokens.verify_dpop_proof(proofs, request) do
          {:ok, jkt} -> {:ok, jkt}
          {:error, _reason} -> {:error, :invalid_dpop_proof}
        end
    end
  end

  def revoke(conn, params) do
    with {:ok, client, _method} <- authenticate_client(params) do
      :ok = OAuth.revoke_token(client.client_id, params["token"])
      conn |> no_store() |> send_resp(200, "")
    else
      {:error, :invalid_client} -> oauth_error(conn, 401, :invalid_client)
    end
  end

  # `private_key_jwt` when the request carries an assertion; otherwise a
  # public client (`none`) named by `client_id`, if its metadata allows that.
  # Reviews issues no client secrets.
  defp authenticate_client(params) do
    cond do
      Map.has_key?(params, "client_assertion") or Map.has_key?(params, "client_assertion_type") ->
        case Tokens.verify_client_assertion(params) do
          {:ok, client} -> {:ok, client, "private_key_jwt"}
          {:error, _reason} -> {:error, :invalid_client}
        end

      Map.has_key?(params, "client_secret") ->
        {:error, :invalid_client}

      is_binary(params["client_id"]) ->
        case Clients.fetch(params["client_id"]) do
          {:ok, client} ->
            if "none" in client.auth_methods,
              do: {:ok, client, "none"},
              else: {:error, :invalid_client}

          {:error, _reason} ->
            {:error, :invalid_client}
        end

      true ->
        {:error, :invalid_client}
    end
  end

  def register(conn, params) do
    if OAuth.public_clients?() do
      case Registration.register_client(params) do
        {:ok, body} ->
          conn |> no_store() |> put_status(:created) |> json(body)

        {:error, error} ->
          conn |> no_store() |> put_status(:bad_request) |> json(%{error: error})

        {:error, error, description} ->
          conn
          |> no_store()
          |> put_status(:bad_request)
          |> json(%{error: error, error_description: description})
      end
    else
      conn |> put_status(:not_found) |> json(%{error: "not_found"})
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
