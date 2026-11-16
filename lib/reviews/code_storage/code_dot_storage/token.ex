defmodule Reviews.CodeStorage.CodeDotStorage.Token do
  @moduledoc """
  ES256 JWT minting for code.storage.

  This module builds the claims. The configured
  `Reviews.CodeStorage.CodeDotStorage.Signer` signs them, so `config` is the
  `Reviews.CodeStorage` config: `:org` plus whatever the signer needs.

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

  alias Reviews.CodeStorage.CodeDotStorage.Signer

  @sub "reviews-server"

  @doc """
  Token for server-to-server API calls (repo create/read/delete) scoped to one
  repository. Short-lived: it exists only for the duration of a request cycle.
  """
  def server_token(config, repo_path, ttl_seconds \\ 300) do
    sign(config, %{
      "repo" => repo_path,
      "scopes" => ["repo:write", "git:read", "org:read"],
      "ttl" => ttl_seconds
    })
  end

  @doc """
  Upload token handed to the CLI: `git:write` only, allowed to update exactly
  the snapshot's two refs. Everything else is rejected by the trailing
  no-push rule. `no-force-push` rejects non-fast-forward updates, but permits
  fast-forwards and deletion. These refs are mutable during the token lifetime;
  consumers must use the verified commit OIDs rather than trust ref immutability.
  """
  def upload_token(config, repo_path, snapshot_public_id, ttl_seconds) do
    sign(config, %{
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

  defp sign(config, %{"ttl" => ttl} = claims) do
    now = System.system_time(:second)

    payload =
      claims
      |> Map.delete("ttl")
      |> Map.merge(%{
        "iss" => config[:org],
        "sub" => @sub,
        "iat" => now,
        "exp" => now + ttl
      })

    Signer.impl(config).sign(payload, config)
  end
end
