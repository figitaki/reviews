defmodule Reviews.CodeStorage.CodeDotStorage.TokenTest do
  use ExUnit.Case, async: true

  alias Reviews.CodeStorage.CodeDotStorage.Token

  # Throwaway P-256 key generated for tests only.
  setup_all do
    jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_meta, pem} = JOSE.JWK.to_pem(jwk)
    %{pem: pem, jwk: jwk}
  end

  defp decode!(token, jwk) do
    {true, %JOSE.JWT{fields: claims}, %JOSE.JWS{alg: {_, alg}}} = JOSE.JWT.verify(jwk, token)
    {claims, alg}
  end

  test "server_token signs ES256 with repo claim and API scopes", %{pem: pem, jwk: jwk} do
    {:ok, token} = Token.server_token("acme", "reviews/abc", pem)
    {claims, alg} = decode!(token, jwk)

    assert alg == :ES256
    assert claims["iss"] == "acme"
    assert claims["sub"] == "reviews-server"
    assert claims["repo"] == "reviews/abc"
    assert claims["scopes"] == ["repo:write", "git:read", "org:read"]
    assert claims["exp"] - claims["iat"] == 300
    refute Map.has_key?(claims, "refs")
  end

  test "upload_token allowlists exactly the snapshot refs", %{pem: pem, jwk: jwk} do
    {:ok, token} = Token.upload_token("acme", "reviews/abc", "snap-id", pem, 900)
    {claims, _alg} = decode!(token, jwk)

    assert claims["scopes"] == ["git:write"]
    assert claims["exp"] - claims["iat"] == 900

    assert claims["refs"] == [
             ["snapshots/snap-id/base", ["no-force-push"]],
             ["snapshots/snap-id/head", ["no-force-push"]],
             ["*", ["no-push"]]
           ]
  end

  test "returns an error for an unusable key" do
    assert {:error, {:jwt_signing_failed, _}} = Token.server_token("acme", "r/x", "not a pem")
  end
end
