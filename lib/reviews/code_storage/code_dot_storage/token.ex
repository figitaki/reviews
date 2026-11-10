defmodule Reviews.CodeStorage.CodeDotStorage.Token do
  @moduledoc """
  ES256 JWT minting for code.storage.

  code.storage verifies tokens with the public half of the organization's
  P-256 API key; we sign with the PKCS8 PEM private key from configuration.

  Claim contract (verified against @pierre/storage v1.16.2):

      %{
        "iss" => org,
        "sub" => client label,
        "repo" => repo path,
        "scopes" => ["git:write", ...],
        "iat" => now,
        "exp" => now + ttl,
        # Ordered ref-policy rules, encoded as [pattern, ops] tuples. A rule
        # with empty ops permits the matched ref; "no-push" rejects updates.
        "refs" => [["snapshots/<id>/base", []], ["*", ["no-push"]]]
      }
  """

  @sub "reviews-server"

  @doc """
  Token for server-to-server API calls (repo create/read/delete) scoped to one
  repository. Short-lived: it exists only for the duration of a request cycle.
  """
  def server_token(org, repo_path, key_pem, ttl_seconds \\ 300) do
    sign(org, key_pem, %{
      "repo" => repo_path,
      "scopes" => ["repo:write", "git:read", "org:read"],
      "ttl" => ttl_seconds
    })
  end

  @doc """
  Upload token handed to the CLI: `git:write` only, allowed to update exactly
  the snapshot's two refs. Everything else is rejected by the trailing
  no-push rule. `no-force-push` on the snapshot refs makes an already-pushed
  ref immutable for the token's remaining lifetime.
  """
  def upload_token(org, repo_path, snapshot_public_id, key_pem, ttl_seconds) do
    sign(org, key_pem, %{
      "repo" => repo_path,
      "scopes" => ["git:write"],
      "refs" => [
        ["snapshots/#{snapshot_public_id}/base", ["no-force-push"]],
        ["snapshots/#{snapshot_public_id}/head", ["no-force-push"]],
        ["*", ["no-push"]]
      ],
      "ttl" => ttl_seconds
    })
  end

  defp sign(org, key_pem, %{"ttl" => ttl} = claims) do
    now = System.system_time(:second)

    payload =
      claims
      |> Map.delete("ttl")
      |> Map.merge(%{
        "iss" => org,
        "sub" => @sub,
        "iat" => now,
        "exp" => now + ttl
      })

    signer = Joken.Signer.create("ES256", %{"pem" => key_pem})

    case Joken.Signer.sign(payload, signer) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, {:jwt_signing_failed, reason}}
    end
  rescue
    # An unusable PEM raises inside Joken/JOSE; report it as a result instead.
    error -> {:error, {:jwt_signing_failed, error.__struct__}}
  end
end
