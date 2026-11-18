defmodule Reviews.OAuthTestClient do
  @moduledoc """
  An OAuth client for tests: an ES256 and a PS384 key in its key set and
  signers for client assertions. Its client ID metadata document and key set
  are served from memory by `Reviews.OAuthTestClient.Fetcher`.
  """

  @issuer "https://reviews.test"

  defstruct [:client_id, :jwks_uri, :redirect_uri, :root, :rsa]

  defmodule Fetcher do
    @moduledoc false
    @behaviour Gatekeep.Fetcher
    @table :oauth_test_fetcher

    def setup do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      end

      :ok
    end

    def put(url, body), do: :ets.insert(@table, {url, body})
    def delete(url), do: :ets.delete(@table, url)

    @impl true
    def get(url, _config) do
      case :ets.lookup(@table, url) do
        [{^url, body}] -> {:ok, %{status: 200, body: JSON.encode!(body)}}
        [] -> {:ok, %{status: 404, body: ""}}
      end
    end
  end

  def issuer, do: @issuer

  @doc """
  A new client with unique URLs, published to the fetcher. `:metadata` adds
  or replaces fields of its metadata document; `public: true` publishes no
  keys and `token_endpoint_auth_method: "none"`.
  """
  def new(opts \\ []) do
    n = System.unique_integer([:positive])
    base = Keyword.get(opts, :base, "https://client#{n}.example")

    client = %__MODULE__{
      client_id: "#{base}/client.json",
      jwks_uri: "#{base}/jwks.json",
      redirect_uri: "#{base}/oauth/callback",
      root: ec_key("root-#{n}"),
      rsa: rsa_key("rsa-#{n}")
    }

    metadata =
      if Keyword.get(opts, :public),
        do: %{"jwks_uri" => nil, "token_endpoint_auth_method" => "none"},
        else: %{}

    publish(client, Map.merge(metadata, Keyword.get(opts, :metadata, %{})))
  end

  @doc "Publishes (or republishes) the client's metadata and key set."
  def publish(client, extra_metadata \\ %{}, keys \\ nil) do
    Fetcher.setup()

    metadata =
      %{
        "client_id" => client.client_id,
        "client_name" => "Test Client",
        "jwks_uri" => client.jwks_uri,
        "redirect_uris" => [client.redirect_uri, "http://127.0.0.1/callback"],
        "token_endpoint_auth_method" => "private_key_jwt"
      }
      |> Map.merge(extra_metadata)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    Fetcher.put(client.client_id, metadata)
    Fetcher.put(client.jwks_uri, %{"keys" => keys || [client.root.public, client.rsa.public]})
    client
  end

  @doc "A private_key_jwt client assertion for the token endpoint."
  def client_assertion(client, opts \\ []) do
    iat = Keyword.get(opts, :iat, now())

    signer =
      case Keyword.get(opts, :key) do
        nil -> if Keyword.get(opts, :rsa), do: client.rsa, else: client.root
        key -> key
      end

    sign(
      %{"alg" => signer.alg, "typ" => "JWT", "kid" => signer.kid},
      %{
        "iss" => Keyword.get(opts, :iss, client.client_id),
        "sub" => Keyword.get(opts, :sub, client.client_id),
        "aud" => Keyword.get(opts, :aud, @issuer),
        "iat" => iat,
        "exp" => Keyword.get(opts, :exp, iat + 120),
        "jti" => Keyword.get(opts, :jti, random_id())
      },
      signer
    )
  end

  @doc "Form params that authenticate the client at the token or revocation endpoint."
  def client_auth(client, opts \\ []) do
    %{
      "client_id" => client.client_id,
      "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      "client_assertion" => client_assertion(client, opts)
    }
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

  @doc "An RSA key; `alg` is `\"PS384\"` (default) or `\"RS256\"`."
  def rsa_key(kid, alg \\ "PS384") do
    {[e, n], private} = :persistent_term.get({__MODULE__, :rsa}, nil) || generate_rsa()

    %{
      alg: alg,
      kid: kid,
      public: %{"kty" => "RSA", "e" => b64(e), "n" => b64(n), "kid" => kid, "alg" => alg},
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

  def sign(header, claims, %{alg: "RS256", private: private}) do
    input = b64(JSON.encode!(header)) <> "." <> b64(JSON.encode!(claims))
    input <> "." <> b64(:crypto.sign(:rsa, :sha256, input, private))
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
