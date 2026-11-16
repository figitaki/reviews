defmodule Reviews.TurnkeyTest do
  @moduledoc """
  Delegations shaped like Turnkey's `turnkey.io/poppy-delegation/v1` profile,
  signed locally. The shapes follow Turnkey's public draft guide; no token here
  came from Turnkey.
  """
  use Reviews.DataCase, async: true

  alias Reviews.OAuth.Clients
  alias Reviews.PoppyTestAgent, as: Agent
  alias Reviews.Turnkey

  setup do
    agent = Agent.turnkey()
    {:ok, client} = Clients.fetch(agent.client_id)
    %{agent: agent, client: client, session_key: Agent.thumbprint(agent.delegated.public)}
  end

  defp verify(ctx, jwt, opts \\ []),
    do: Turnkey.verify_delegation(jwt, ctx.client, Keyword.get(opts, :key, ctx.session_key), opts)

  describe "hosted_agent/1" do
    test "reads the organization and slug of a Turnkey agent URL, and nothing else" do
      org = "5f0c3b8e-1d2a-4c55-9f0e-6a1b2c3d4e5f"

      assert {:ok, %{organization_id: ^org, agent: "shopper"}} =
               Turnkey.hosted_agent("https://id.turnkey.com/t/#{org}/agents/shopper/agent.json")

      for url <- [
            "https://id.turnkey.com.evil.example/t/#{org}/agents/shopper/agent.json",
            "https://evil.example/t/#{org}/agents/shopper/agent.json",
            "http://id.turnkey.com/t/#{org}/agents/shopper/agent.json",
            "https://id.turnkey.com:8443/t/#{org}/agents/shopper/agent.json",
            "https://id.turnkey.com:443/t/#{org}/agents/shopper/agent.json",
            "https://id.turnkey.com/t/#{org}/agents/Shopper/agent.json",
            "https://id.turnkey.com/t/#{org}/agents/shopper/jwks.json",
            "https://id.turnkey.com/t/#{org}/agents/a/b/agent.json",
            "https://id.turnkey.com/t//agents/shopper/agent.json",
            "https://id.turnkey.com/t/#{org}/agents/shopper/agent.json?x=1",
            "https://id.turnkey.com/t/#{org}/agents/#{String.duplicate("a", 65)}/agent.json"
          ] do
        assert Turnkey.hosted_agent(url) == :error, url
      end
    end
  end

  describe "verify_delegation/4" do
    test "accepts the profile's delegation for the session key", ctx do
      assert {:ok, verified} = verify(ctx, ctx.agent.delegation)
      assert verified.profile == "turnkey.io/poppy-delegation/v1"
      assert verified.agent == "shopper"
      assert verified.identity_key == ctx.agent.root.kid
      assert {:ok, %{organization_id: org}} = Turnkey.hosted_agent(ctx.agent.client_id)
      assert verified.organization_id == org
    end

    test "refuses a delegation from another issuer or key", ctx do
      other = Agent.turnkey()

      assert {:error, :iss_mismatch} =
               verify(ctx, Agent.delegation(ctx.agent, iss: other.client_id))

      # Another agent's key, under its own kid or posing as this agent's.
      assert {:error, :unknown_key} =
               verify(ctx, Agent.delegation(ctx.agent, signer: other.root))

      assert {:error, :bad_signature} =
               verify(
                 ctx,
                 Agent.delegation(ctx.agent, signer: other.root, kid: ctx.agent.root.kid)
               )

      # The same claims from an agent that isn't hosted by Turnkey.
      plain = Agent.new()
      {:ok, plain_client} = Clients.fetch(plain.client_id)

      assert {:error, :not_turnkey_hosted} =
               Turnkey.verify_delegation(
                 plain.delegation,
                 plain_client,
                 Agent.thumbprint(plain.delegated.public)
               )
    end

    test "refuses an expired, future, or too-long delegation", ctx do
      now = Agent.now()

      assert {:error, :expired} =
               verify(ctx, Agent.delegation(ctx.agent, iat: now - 7200, exp: now - 31))

      assert {:ok, _} = verify(ctx, Agent.delegation(ctx.agent, iat: now - 7200, exp: now - 29))

      assert {:error, :issued_in_future} =
               verify(ctx, Agent.delegation(ctx.agent, iat: now + 60, exp: now + 3600))

      assert {:error, :bad_lifetime} =
               verify(ctx, Agent.delegation(ctx.agent, iat: now, exp: now + 86_401))

      assert {:ok, _} = verify(ctx, Agent.delegation(ctx.agent, iat: now, exp: now + 86_400))
    end

    test "refuses a delegation that names an audience, since the profile has none", ctx do
      assert {:error, :unexpected_claims} =
               verify(
                 ctx,
                 Agent.delegation(ctx.agent, claims: %{"aud" => "https://reviews.test"})
               )

      assert {:error, :unexpected_header} =
               verify(ctx, Agent.delegation(ctx.agent, header: %{"jku" => ctx.agent.jwks_uri}))
    end

    test "refuses a delegation for a different session key, or for the identity key", ctx do
      other_key = Agent.ec_key(nil)

      assert {:error, :different_session_key} =
               verify(ctx, ctx.agent.delegation, key: Agent.thumbprint(other_key.public))

      root = Map.take(ctx.agent.root.public, ["kty", "crv", "x", "y"])

      assert {:error, :delegated_identity_key} =
               verify(ctx, Agent.delegation(ctx.agent, cnf: root), key: ctx.agent.root.kid)
    end

    test "refuses tampering with the claims, header, or delegated key", ctx do
      [h, c, s] = String.split(ctx.agent.delegation, ".")
      claims = c |> Base.url_decode64!(padding: false) |> JSON.decode!()
      longer = JSON.encode!(%{claims | "exp" => claims["exp"] + 3600})
      tampered = Enum.join([h, Base.url_encode64(longer, padding: false), s], ".")
      assert {:error, :bad_signature} = verify(ctx, tampered)

      assert {:error, :bad_typ} = verify(ctx, Agent.delegation(ctx.agent, typ: "JWT"))

      private = Map.put(ctx.agent.delegated.public, "d", "AAAA")
      assert {:error, :bad_delegated_key} = verify(ctx, Agent.delegation(ctx.agent, cnf: private))

      with_kid = Map.put(ctx.agent.delegated.public, "kid", "k1")

      assert {:error, :bad_delegated_key} =
               verify(ctx, Agent.delegation(ctx.agent, cnf: with_kid))

      assert {:error, :bad_jti} = verify(ctx, Agent.delegation(ctx.agent, jti: "short"))
      assert {:error, :malformed} = verify(ctx, "not.a.jwt")
    end

    test "refuses a key whose kid isn't its thumbprint", ctx do
      key = Agent.ec_key("identity-1")
      Agent.publish(ctx.agent, %{"client_name" => "Shopper"}, [key.public])
      Clients.forget(ctx.agent.client_id)
      {:ok, client} = Clients.fetch(ctx.agent.client_id)

      assert {:error, :kid_not_thumbprint} =
               Turnkey.verify_delegation(
                 Agent.delegation(ctx.agent, signer: key),
                 client,
                 ctx.session_key
               )
    end
  end
end
