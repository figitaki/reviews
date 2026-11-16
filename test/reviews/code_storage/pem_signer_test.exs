defmodule Reviews.CodeStorage.CodeDotStorage.PemSignerTest do
  use ExUnit.Case, async: true

  alias Reviews.CodeStorage.CodeDotStorage.PemSigner

  setup_all do
    jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, pem} = JOSE.JWK.to_pem(jwk)
    %{jwk: jwk, pem: pem}
  end

  describe "sign/2" do
    test "signs named-curve P-256 with actual, escaped, and CRLF newlines", ctx do
      for pem <- [
            ctx.pem,
            String.replace(ctx.pem, "\n", "\\n"),
            String.replace(ctx.pem, "\n", "\r\n")
          ] do
        assert {:ok, jwt} = PemSigner.sign(%{"sub" => "synthetic"}, jwt_private_key: pem)

        assert {true, %JOSE.JWT{fields: %{"sub" => "synthetic"}}, _} =
                 JOSE.JWT.verify_strict(JOSE.JWK.to_public(ctx.jwk), ["ES256"], jwt)
      end
    end

    test "rejects explicit EC parameters with a stable, sanitized error" do
      pem = File.read!("test/support/fixtures/code_storage/synthetic_explicit_p256.pem")
      assert_invalid(pem)
    end

    test "rejects a different curve" do
      {_, pem} = JOSE.JWK.generate_key({:ec, :secp384r1}) |> JOSE.JWK.to_pem()
      assert_invalid(pem)
    end

    test "requires a private key", ctx do
      {_, pem} = ctx.jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
      assert_invalid(pem)
    end

    test "rejects encrypted private keys", ctx do
      {_, pem} = JOSE.JWK.to_pem("synthetic-test-passphrase", ctx.jwk)
      assert_invalid(pem)
    end

    test "does not accept a bundle of keys", ctx do
      assert_invalid(ctx.pem <> ctx.pem)
    end

    test "rejects malformed and non-string inputs without echoing their contents" do
      for pem <- ["SYNTHETIC_SECRET_SENTINEL", "", %{"key" => "SYNTHETIC_SECRET_SENTINEL"}] do
        assert_invalid(pem)
      end
    end

    test "keeps missing configuration distinct" do
      assert {:error, :code_storage_misconfigured} = PemSigner.sign(%{}, [])
    end
  end

  defp assert_invalid(pem) do
    assert {:error, {:jwt_signing_failed, :invalid_named_curve_p256_pem}} =
             PemSigner.sign(%{"sub" => "synthetic"}, jwt_private_key: pem)
  end
end
