defmodule Reviews.PoppyTestAgent do
  @moduledoc """
  A Poppy Personal Agent for tests: an ES256 root key and a PS384 root key in
  its key set, a delegated key, and signers for delegations, Session JWTs, and
  client assertions. Its client metadata and key set are served from memory by
  `Reviews.PoppyTestAgent.Fetcher`.
  """

  @issuer "https://reviews.test"

  defstruct [:client_id, :jwks_uri, :redirect_uri, :root, :rsa, :delegated, :delegation, :sub]

  defmodule Fetcher do
    @moduledoc "The issuer's in-memory test fetcher, which serves agents' metadata too."
    defdelegate setup, to: Reviews.OAuthTestClient.Fetcher
    defdelegate put(url, body), to: Reviews.OAuthTestClient.Fetcher
    defdelegate delete(url), to: Reviews.OAuthTestClient.Fetcher
  end

  def issuer, do: @issuer

  @doc "A new agent with unique URLs, published to the fetcher."
  def new(opts \\ []) do
    n = System.unique_integer([:positive])
    base = Keyword.get(opts, :base, "https://agent#{n}.example")
    client_id = "#{base}/agent.json"

    agent = %__MODULE__{
      client_id: client_id,
      jwks_uri: "#{base}/jwks.json",
      redirect_uri: "#{base}/oauth/callback",
      root: ec_key("root-#{n}"),
      rsa: rsa_key("rsa-#{n}"),
      delegated: ec_key(nil),
      sub: "usr_" <> random_id()
    }

    agent = %{agent | delegation: delegation(agent)}
    publish(agent, Keyword.get(opts, :metadata, %{}))
  end

  @doc """
  A Personal Agent hosted the way Turnkey's draft Personal Agent Protocol
  guide describes: `client_id` at `https://id.turnkey.com/t/<org>/agents/<slug>/agent.json`,
  its key set next to it, and one P-256 identity key whose `kid` is its RFC
  7638 thumbprint, with `use` and `alg`. Its delegations and client
  assertions have the shapes of `turnkey.io/poppy-delegation/v1` and
  `turnkey.io/client-assertion/v1`. `:host`, `:org`, and `:slug` change the
  URL; `:redirect_uris` replaces the metadata's list.
  """
  def turnkey(opts \\ []) do
    host = Keyword.get(opts, :host, "id.turnkey.com")
    org = Keyword.get_lazy(opts, :org, &uuid/0)
    slug = Keyword.get(opts, :slug, "shopper")
    base = "https://#{host}/t/#{org}/agents/#{slug}"
    root = turnkey_key()

    agent = %__MODULE__{
      client_id: "#{base}/agent.json",
      jwks_uri: "#{base}/jwks.json",
      redirect_uri: "#{base}/callback",
      root: root,
      rsa: rsa_key("unused"),
      delegated: ec_key(nil),
      sub: "usr_" <> random_id()
    }

    agent = %{agent | delegation: delegation(agent)}

    metadata = %{
      "client_name" => "Shopper",
      "redirect_uris" => Keyword.get(opts, :redirect_uris, [agent.redirect_uri]),
      "token_endpoint_auth_signing_alg" => "ES256"
    }

    publish(agent, metadata, [root.public])
  end

  @doc "A P-256 key published as Turnkey's guide lists agent keys."
  def turnkey_key do
    key = ec_key(nil)
    kid = thumbprint(key.public)

    %{
      key
      | kid: kid,
        public: Map.merge(key.public, %{"kid" => kid, "use" => "sig", "alg" => "ES256"})
    }
  end

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  @doc "Publishes (or republishes) the agent's metadata and key set."
  def publish(agent, extra_metadata \\ %{}, keys \\ nil) do
    Fetcher.setup()

    Fetcher.put(
      agent.client_id,
      Map.merge(
        %{
          "client_id" => agent.client_id,
          "client_name" => "Test Agent",
          "jwks_uri" => agent.jwks_uri,
          "redirect_uris" => [agent.redirect_uri, "http://127.0.0.1/callback"],
          "token_endpoint_auth_method" => "private_key_jwt"
        },
        extra_metadata
      )
    )

    Fetcher.put(agent.jwks_uri, %{"keys" => keys || [agent.root.public, agent.rsa.public]})
    agent
  end

  @doc """
  A delegation for the agent's delegated key (spec 5.2). `:signer` signs with
  another key, and `:header` and `:claims` add or replace members.
  """
  def delegation(agent, opts \\ []) do
    now = now()
    iat = Keyword.get(opts, :iat, now - 60)

    signer =
      Keyword.get(opts, :signer, if(Keyword.get(opts, :rsa), do: agent.rsa, else: agent.root))

    delegated = Keyword.get(opts, :delegated, agent.delegated)

    header =
      Map.merge(
        %{
          "alg" => signer.alg,
          "typ" => Keyword.get(opts, :typ, "poppy-delegation+jwt"),
          "kid" => Keyword.get(opts, :kid, signer.kid)
        },
        Keyword.get(opts, :header, %{})
      )

    claims =
      Map.merge(
        %{
          "iss" => Keyword.get(opts, :iss, agent.client_id),
          "cnf" => %{"jwk" => Keyword.get(opts, :cnf, delegated.public)},
          "iat" => iat,
          "exp" => Keyword.get(opts, :exp, iat + 6 * 60 * 60),
          "jti" => Keyword.get(opts, :jti, random_id())
        },
        Keyword.get(opts, :claims, %{})
      )

    sign(header, claims, signer)
  end

  @doc "A Session JWT for one request (spec 5.2)."
  def session_jwt(agent, method, url, opts \\ []) do
    key = Keyword.get(opts, :key, agent.delegated)

    header =
      %{
        "typ" => Keyword.get(opts, :typ, "poppy-session+jwt"),
        "alg" => "ES256",
        "kid" => Keyword.get(opts, :kid, thumbprint(key.public))
      }
      |> put_unless_nil("poppy_dlg", Keyword.get(opts, :delegation, agent.delegation))

    claims =
      %{
        "iss" => Keyword.get(opts, :iss, agent.client_id),
        "aud" => Keyword.get(opts, :aud, @issuer),
        "sid" => Keyword.get(opts, :sid, "sid_default"),
        "sub" => Keyword.get(opts, :sub, agent.sub),
        "htm" => Keyword.get(opts, :htm, method),
        "htu" => Keyword.get(opts, :htu, url),
        "iat" => Keyword.get(opts, :iat, now()),
        "jti" => Keyword.get(opts, :jti, random_id())
      }
      |> put_unless_nil("agent_id", Keyword.get(opts, :agent_id))
      |> put_unless_nil("ath", ath(opts))

    sign(header, claims, key)
  end

  defp ath(opts) do
    case Keyword.fetch(opts, :ath) do
      {:ok, value} -> value
      :error -> if token = opts[:access_token], do: Reviews.OAuth.JOSE.digest(token)
    end
  end

  @doc """
  A DPoP proof (RFC 9449 §4.2) signed with `key`, an `ec_key/1`, for `method`
  and `url`. `:access_token` adds its `ath`.
  """
  def dpop_proof(key, method, url, opts \\ []) do
    header = %{
      "typ" => Keyword.get(opts, :typ, "dpop+jwt"),
      "alg" => "ES256",
      "jwk" => Keyword.get(opts, :jwk, key.public)
    }

    claims =
      %{
        "jti" => Keyword.get(opts, :jti, random_id()),
        "htm" => Keyword.get(opts, :htm, method),
        "htu" => Keyword.get(opts, :htu, url),
        "iat" => Keyword.get(opts, :iat, now())
      }
      |> put_unless_nil("ath", ath(opts))

    sign(header, claims, key)
  end

  @doc "A private_key_jwt client assertion for the token endpoint (spec 4.1)."
  def client_assertion(agent, opts \\ []) do
    now = now()
    iat = Keyword.get(opts, :iat, now)
    signer = if Keyword.get(opts, :rsa), do: agent.rsa, else: agent.root

    sign(
      %{"alg" => signer.alg, "typ" => "JWT", "kid" => signer.kid},
      %{
        "iss" => Keyword.get(opts, :iss, agent.client_id),
        "sub" => Keyword.get(opts, :sub, agent.client_id),
        "aud" => Keyword.get(opts, :aud, @issuer),
        "iat" => iat,
        "exp" => Keyword.get(opts, :exp, iat + 120),
        "jti" => Keyword.get(opts, :jti, random_id())
      },
      signer
    )
  end

  @doc "Form params that authenticate the agent at the token or revocation endpoint."
  def client_auth(agent, opts \\ []) do
    %{
      "client_id" => agent.client_id,
      "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      "client_assertion" => client_assertion(agent, opts)
    }
  end

  @doc """
  Poppy request headers for `method` and `path` on the test issuer. With
  `:dpop_key`, the token is sent with the DPoP scheme and a proof from that key;
  `:dpop` holds options for the proof and `:scheme` overrides the scheme.
  """
  def headers(agent, method, path, opts \\ []) do
    jwt = session_jwt(agent, method, @issuer <> path, opts)
    token = opts[:access_token]
    dpop_key = opts[:dpop_key]
    scheme = Keyword.get(opts, :scheme, if(dpop_key, do: "DPoP", else: "Bearer"))

    [{"poppy-session", jwt}, {"poppy-version", Keyword.get(opts, :version, "1.0")}] ++
      if(token, do: [{"authorization", scheme <> " " <> token}], else: []) ++
      if dpop_key do
        proof_opts = Keyword.merge([access_token: token], Keyword.get(opts, :dpop, []))
        [{"dpop", dpop_proof(dpop_key, method, @issuer <> path, proof_opts)}]
      else
        []
      end
  end

  ## Keys and signing

  def ec_key(kid) do
    {<<4, x::binary-size(32), y::binary-size(32)>>, d} = :crypto.generate_key(:ecdh, :secp256r1)

    public =
      %{"kty" => "EC", "crv" => "P-256", "x" => b64(x), "y" => b64(y)}
      |> put_unless_nil("kid", kid)
      |> put_unless_nil("alg", kid && "ES256")

    %{alg: "ES256", kid: kid, public: public, private: d}
  end

  def rsa_key(kid) do
    {[e, n], private} = :persistent_term.get({__MODULE__, :rsa}, nil) || generate_rsa()

    %{
      alg: "PS384",
      kid: kid,
      public: %{"kty" => "RSA", "e" => b64(e), "n" => b64(n), "kid" => kid, "alg" => "PS384"},
      private: private
    }
  end

  defp generate_rsa do
    key = :crypto.generate_key(:rsa, {2048, 65_537})
    :persistent_term.put({__MODULE__, :rsa}, key)
    key
  end

  def sign(header, claims, %{alg: "ES256", private: d}) do
    input = b64(JSON.encode!(header)) <> "." <> b64(JSON.encode!(claims))
    der = :crypto.sign(:ecdsa, :sha256, input, [d, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64(<<r::256, s::256>>)
  end

  def sign(header, claims, %{alg: "PS384", private: private}) do
    input = b64(JSON.encode!(header)) <> "." <> b64(JSON.encode!(claims))

    sig =
      :crypto.sign(:rsa, :sha384, input, private,
        rsa_padding: :rsa_pkcs1_pss_padding,
        rsa_pss_saltlen: 48,
        rsa_mgf1_md: :sha384
      )

    input <> "." <> b64(sig)
  end

  def thumbprint(jwk) do
    {:ok, value} = Reviews.OAuth.JOSE.thumbprint(jwk)
    value
  end

  def pkce do
    verifier = random_id() <> random_id()
    {verifier, Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)}
  end

  def random_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  def now, do: System.system_time(:second)

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
