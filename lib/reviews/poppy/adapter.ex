defmodule Reviews.Poppy.Adapter do
  @moduledoc """
  `Reviews.ExternalIdentity` for Poppy 1.0 requests: a `Poppy-Session` header,
  `Poppy-Version`, and, when signed in, an access token from Direct Sign-In.

  Order of checks (spec 3.4, 5.3): version, Session JWT and delegation, the
  access token and its link, that the token was issued to the JWT's `iss`, then
  the Session record.
  """
  @behaviour Reviews.ExternalIdentity

  alias Reviews.Poppy
  alias Reviews.Poppy.Tokens

  @impl true
  def authenticate(%{method: method, url: url, headers: headers}, opts \\ []) do
    token = bearer(headers["authorization"])

    with :ok <- check_version(headers["poppy-version"]),
         {:ok, jwt} <- session_header(headers["poppy-session"]),
         {:ok, claims} <-
           Tokens.verify_session(jwt, %{method: method, url: url, access_token: token}, opts),
         {:ok, grant} <- access(token),
         :ok <- same_client(grant, claims),
         {:ok, session} <- Poppy.touch_session(claims, grant && grant.link.identity_id) do
      {:ok, result(claims, grant, session)}
    end
  end

  # Compatible versions share the major version (spec 3.4).
  defp check_version("1." <> minor) do
    if minor =~ ~r/\A\d+\z/, do: :ok, else: {:error, :version_unsupported}
  end

  defp check_version(_), do: {:error, :version_unsupported}

  defp session_header(jwt) when is_binary(jwt) and jwt != "", do: {:ok, jwt}
  defp session_header(_), do: {:error, :missing_session}

  defp bearer("Bearer " <> token) when token != "", do: token
  defp bearer(_), do: nil

  defp access(nil), do: {:ok, nil}
  defp access(token), do: Poppy.authenticate_access_token(token)

  # Spec 5.3 step 3: the token was issued to the same client_id as `iss`.
  defp same_client(nil, _claims), do: :ok

  defp same_client(%{link: link}, %{client: client}) do
    if link.subject == client.client_id, do: :ok, else: {:error, :token_client_mismatch}
  end

  defp result(claims, nil, session) do
    %{
      identity: nil,
      owner: nil,
      link: nil,
      scopes: [],
      attribution: attribution(claims, nil, session)
    }
  end

  defp result(claims, %{link: link, scopes: scopes}, session) do
    %{
      identity: link.identity,
      owner: link.approved_by_user,
      link: link,
      scopes: scopes,
      attribution: attribution(claims, link, session)
    }
  end

  # What was verified, kept with the records the request creates. The
  # Personal Agent's name and Agent ID are its own claims; the owner and agent
  # identity come from the owner's approval in Reviews. Poppy 1.0 has no
  # workload attestation or owner-to-agent delegation chain, so neither is
  # recorded as verified.
  defp attribution(claims, link, session) do
    %{
      "provider" => Poppy.provider(),
      "protocol_version" => Poppy.protocol_version(),
      "verified_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "client_id" => claims.client.client_id,
      "client_name_claimed" => claims.client.client_name,
      "session_id" => session.id,
      "user_id" => claims.sub,
      "agent_id_claimed" => claims.agent_id,
      "delegated_key" => claims.delegated_key,
      "delegation_expires_at" =>
        DateTime.from_unix!(claims.delegation_exp) |> DateTime.to_iso8601()
    }
    |> Map.merge(link_attribution(link))
  end

  defp link_attribution(nil), do: %{}

  defp link_attribution(link) do
    %{
      "link_id" => link.id,
      "approved_at" => DateTime.to_iso8601(link.inserted_at),
      "owner_user_id" => link.approved_by_user_id,
      "owner_username" => link.approved_by_user.username,
      "identity_id" => link.identity_id,
      "identity_handle" => link.identity.handle
    }
  end
end
