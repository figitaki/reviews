defmodule Reviews.CodeStorage.CodeDotStorage.PemSigner do
  @moduledoc """
  Signs code.storage JWTs with the P-256 private key in `:jwt_private_key`
  (unencrypted PKCS8 PEM with named-curve parameters, from
  `CODE_STORAGE_JWT_PRIVATE_KEY`). Literal `\\n` separators are also accepted.
  """
  @behaviour Reviews.CodeStorage.CodeDotStorage.Signer

  @impl true
  def sign(claims, config) do
    case config[:jwt_private_key] do
      nil -> {:error, :code_storage_misconfigured}
      pem when is_binary(pem) -> sign_with_pem(claims, pem)
      _ -> invalid_key()
    end
  end

  defp sign_with_pem(claims, pem) do
    with {:ok, jwk} <- load_key(pem) do
      sign_with_key(claims, jwk)
    end
  end

  defp load_key(pem) do
    pem = pem |> String.replace("\\r\\n", "\n") |> String.replace("\\n", "\n")

    with [{:PrivateKeyInfo, _, :not_encrypted}] <- :public_key.pem_decode(pem),
         %JOSE.JWK{} = jwk <- JOSE.JWK.from_pem(pem),
         {_, %{"kty" => "EC", "crv" => "P-256", "d" => d}} when is_binary(d) and d != "" <-
           JOSE.JWK.to_map(jwk) do
      {:ok, jwk}
    else
      _ -> invalid_key()
    end
  rescue
    # OTP's decoder rejects explicit EC parameters. Never include the decoder's
    # exception text or payload: ASN.1 errors can contain private key material.
    _ -> invalid_key()
  end

  defp sign_with_key(claims, jwk) do
    signer = Joken.Signer.create("ES256", jwk)

    case Joken.Signer.sign(claims, signer) do
      {:ok, token} -> {:ok, token}
      {:error, _reason} -> {:error, {:jwt_signing_failed, :signing_failed}}
    end
  rescue
    _ -> {:error, {:jwt_signing_failed, :signing_failed}}
  end

  defp invalid_key, do: {:error, {:jwt_signing_failed, :invalid_named_curve_p256_pem}}
end
