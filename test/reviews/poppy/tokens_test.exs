defmodule Reviews.Poppy.TokensTest do
  use Reviews.DataCase, async: true

  alias Reviews.OAuth.{Clients, JOSE}
  alias Reviews.Poppy.Tokens
  alias Reviews.PoppyTestAgent, as: Agent

  @url "https://reviews.test/api/poppy/v1/reviews/abc"

  defp verify(jwt, opts \\ []) do
    request = %{
      method: Keyword.get(opts, :method, "GET"),
      url: Keyword.get(opts, :url, @url),
      access_token: opts[:access_token]
    }

    Tokens.verify_session(jwt, request, Keyword.take(opts, [:now]))
  end

  describe "official kit vectors" do
    setup do
      vectors =
        "test/support/fixtures/poppy/kit_vectors.json" |> File.read!() |> JSON.decode!()

      Agent.Fetcher.put(vectors["metadata"]["client_id"], vectors["metadata"])
      Agent.Fetcher.put(vectors["metadata"]["jwks_uri"], vectors["jwks"])
      %{v: vectors}
    end

    test "accepts Session JWTs and client assertions the kit signed", %{v: v} do
      now = v["now"]
      thumbprint = v["delegated_key_thumbprint"]

      for name <- ["signed_out", "ps384_delegation"] do
        s = v["sessions"][name]

        assert {:ok, claims} =
                 verify(s["jwt"], method: s["method"], url: s["url"], now: now),
               name

        assert claims.sid == "kit_session_1"
        assert claims.sub == "kit_user_1"
        assert claims.delegated_key == thumbprint
      end

      s = v["sessions"]["signed_in"]

      assert {:ok, %{agent_id: "kit_agent_1"}} =
               verify(s["jwt"],
                 method: s["method"],
                 url: s["url"],
                 access_token: s["access_token"],
                 now: now
               )

      for {name, jwt} <- v["client_assertions"] do
        params = %{
          "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
          "client_assertion" => jwt
        }

        assert {:ok, %{client_id: "https://kit-agent.example/agent.json"}} =
                 Reviews.OAuth.Tokens.verify_client_assertion(params, now: now),
               name
      end
    end

    test "rejects the kit's Session JWT replayed, late, or for another request", %{v: v} do
      s = v["sessions"]["signed_out"]
      now = v["now"]

      assert {:error, :expired} = verify(s["jwt"], now: now + 120)
      assert {:error, :wrong_method} = verify(s["jwt"], method: "POST", now: now)

      assert {:error, :wrong_url} =
               verify(s["jwt"], url: "https://reviews.test/api/poppy/v1/reviews/xyz", now: now)

      assert {:ok, _} = verify(s["jwt"], now: now)
      assert {:error, :replayed} = verify(s["jwt"], now: now)

      signed_in = v["sessions"]["signed_in"]

      assert {:error, :ath_mismatch} =
               verify(signed_in["jwt"],
                 method: "POST",
                 url: signed_in["url"],
                 access_token: "ppa_another_token",
                 now: now
               )
    end
  end

  describe "verify_session/3" do
    setup do
      %{agent: Agent.new()}
    end

    test "accepts a fresh Session JWT once, then refuses the replay", %{agent: agent} do
      jwt = Agent.session_jwt(agent, "GET", @url, agent_id: "agt_1")

      assert {:ok, claims} = verify(jwt)
      assert claims.client.client_id == agent.client_id
      assert claims.sub == agent.sub
      assert claims.agent_id == "agt_1"

      assert {:error, :replayed} = verify(jwt)
    end

    test "refuses expired and future-dated JWTs", %{agent: agent} do
      now = Agent.now()

      assert {:error, :expired} = verify(Agent.session_jwt(agent, "GET", @url, iat: now - 120))

      assert {:error, :issued_in_future} =
               verify(Agent.session_jwt(agent, "GET", @url, iat: now + 120))
    end

    test "refuses another audience, including the API URL or a trailing slash", %{agent: agent} do
      for aud <- ["https://other.example", "https://reviews.test/", @url] do
        assert {:error, :wrong_audience} = verify(Agent.session_jwt(agent, "GET", @url, aud: aud))
      end
    end

    test "refuses a JWT signed directly with a root key, or without a delegation", %{agent: agent} do
      assert {:error, :missing_delegation} =
               verify(Agent.session_jwt(agent, "GET", @url, delegation: nil))

      signed_by_root =
        Agent.session_jwt(agent, "GET", @url, key: agent.root, kid: agent.root.kid)

      assert {:error, :bad_signature} = verify(signed_by_root)
    end

    test "refuses bad delegations", %{agent: agent} do
      now = Agent.now()
      other = Agent.new()

      cases = [
        delegation_expired: Agent.delegation(agent, iat: now - 7200, exp: now - 3600),
        delegation_too_long: Agent.delegation(agent, iat: now - 60, exp: now + 24 * 3600),
        delegation_iss_mismatch: Agent.delegation(agent, iss: other.client_id),
        bad_delegation_typ: Agent.delegation(agent, typ: "poppy-session+jwt"),
        unknown_delegation_key: Agent.delegation(agent, kid: "not-in-jwks"),
        # Signed by another agent's root key under this agent's kid.
        bad_delegation_signature:
          Agent.delegation(%{other | root: %{other.root | kid: agent.root.kid}})
      ]

      for {reason, delegation} <- cases do
        assert {:error, ^reason} =
                 verify(Agent.session_jwt(agent, "GET", @url, delegation: delegation)),
               "expected #{reason}"
      end
    end

    test "accepts a PS384 delegation, as a blind signature would be", %{agent: agent} do
      delegation = Agent.delegation(agent, rsa: true)
      assert {:ok, _} = verify(Agent.session_jwt(agent, "GET", @url, delegation: delegation))
    end

    test "refuses a header kid that isn't the delegated key's thumbprint", %{agent: agent} do
      assert {:error, :kid_not_thumbprint} =
               verify(Agent.session_jwt(agent, "GET", @url, kid: "something-else"))
    end

    test "binds ath to the access token", %{agent: agent} do
      with_token = Agent.session_jwt(agent, "POST", @url, access_token: "ppa_one")

      assert {:error, :ath_without_token} = verify(with_token, method: "POST")

      assert {:error, :missing_ath} =
               verify(Agent.session_jwt(agent, "POST", @url),
                 method: "POST",
                 access_token: "ppa_one"
               )

      assert {:ok, _} = verify(with_token, method: "POST", access_token: "ppa_one")
    end

    test "a key removed from jwks_uri stops verifying once the cache is refreshed", %{
      agent: agent
    } do
      assert {:ok, _} = verify(Agent.session_jwt(agent, "GET", @url))

      Agent.publish(agent, %{}, [agent.rsa.public])
      Clients.forget(agent.client_id)

      assert {:error, :unknown_delegation_key} = verify(Agent.session_jwt(agent, "GET", @url))
    end

    test "refuses client metadata whose client_id doesn't match its URL" do
      agent = Agent.new(metadata: %{"client_id" => "https://elsewhere.example/agent.json"})

      assert {:error, :invalid_client_metadata} = verify(Agent.session_jwt(agent, "GET", @url))
    end
  end
end
