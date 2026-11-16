defmodule Reviews.OAuth.JOSE do
  @moduledoc """
  The small part of JOSE the issuer needs on the verifying side: compact JWS
  decoding, ES256, PS384, and RS256 signature checks, and RFC 7638
  thumbprints.

  Verification only. Callers choose which algorithms a JWT type allows; `none`
  and symmetric algorithms are never used. Callers also choose the key: keys
  embedded in a JWT (`jku`, `x5u`, `jwk`) are used only for DPoP proofs, whose
  `jwk` header is how they work (RFC 9449 §4.2).
  """

  @type decoded :: %{
          header: map(),
          claims: map(),
          signing_input: binary(),
          signature: binary()
        }

  @doc "Splits and decodes a compact JWS. Does not check the signature."
  @spec decode(String.t()) :: {:ok, decoded()} | {:error, :malformed}
  def decode(jwt) when is_binary(jwt) and byte_size(jwt) <= 16_384 do
    with [h64, c64, s64] <- String.split(jwt, "."),
         {:ok, header_json} <- b64url_decode(h64),
         {:ok, claims_json} <- b64url_decode(c64),
         {:ok, signature} <- b64url_decode(s64),
         {:ok, %{} = header} <- JSON.decode(header_json),
         {:ok, %{} = claims} <- JSON.decode(claims_json) do
      {:ok,
       %{header: header, claims: claims, signing_input: h64 <> "." <> c64, signature: signature}}
    else
      _ -> {:error, :malformed}
    end
  end

  def decode(_), do: {:error, :malformed}

  @doc """
  Verifies `decoded` with `jwk`, accepting only the algorithms in `allowed`
  (`"ES256"`, `"PS384"`, and `"RS256"`). The key type must match the
  algorithm.
  """
  @spec verify(decoded(), map(), [String.t()]) :: boolean()
  def verify(%{header: %{"alg" => alg}} = decoded, jwk, allowed) when is_map(jwk) do
    alg in allowed and verify_alg(alg, decoded, jwk)
  end

  def verify(_decoded, _jwk, _allowed), do: false

  defp verify_alg("ES256", %{signing_input: input, signature: <<r::256, s::256>>}, jwk) do
    with {:ok, point} <- ec_point(jwk) do
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
      safe_verify(fn -> :crypto.verify(:ecdsa, :sha256, input, der, [point, :secp256r1]) end)
    else
      _ -> false
    end
  end

  defp verify_alg("PS384", %{signing_input: input, signature: signature}, jwk) do
    with {:ok, [e, n]} <- rsa_key(jwk),
         true <- byte_size(signature) == byte_size(n) do
      safe_verify(fn ->
        :crypto.verify(:rsa, :sha384, input, signature, [e, n],
          rsa_padding: :rsa_pkcs1_pss_padding,
          rsa_pss_saltlen: 48,
          rsa_mgf1_md: :sha384
        )
      end)
    else
      _ -> false
    end
  end

  # ChatGPT signs its client assertions with RS256 (its CIMD document says so).
  defp verify_alg("RS256", %{signing_input: input, signature: signature}, jwk) do
    with {:ok, [e, n]} <- rsa_key(jwk),
         true <- byte_size(signature) == byte_size(n) do
      safe_verify(fn -> :crypto.verify(:rsa, :sha256, input, signature, [e, n]) end)
    else
      _ -> false
    end
  end

  defp verify_alg(_alg, _decoded, _jwk), do: false

  defp safe_verify(fun) do
    fun.() == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc "True when `jwk` is a public key the issuer accepts (no private members)."
  def public_key?(%{"kty" => "EC"} = jwk),
    do: not Map.has_key?(jwk, "d") and ec_point(jwk) != :error

  def public_key?(%{"kty" => "RSA"} = jwk),
    do: not Map.has_key?(jwk, "d") and rsa_key(jwk) != :error

  def public_key?(_), do: false

  defp ec_point(%{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y})
       when is_binary(x) and is_binary(y) do
    case {b64url_decode(x), b64url_decode(y)} do
      {{:ok, <<_::binary-size(32)>> = xb}, {:ok, <<_::binary-size(32)>> = yb}} ->
        {:ok, <<4, xb::binary, yb::binary>>}

      _ ->
        :error
    end
  end

  defp ec_point(_), do: :error

  # RSA keys of 2048 to 4096 bits (guides, "Signing and verifying JWTs").
  defp rsa_key(%{"kty" => "RSA", "n" => n, "e" => e}) when is_binary(n) and is_binary(e) do
    with {:ok, nb} <- b64url_decode(n),
         {:ok, eb} <- b64url_decode(e),
         bits when bits >= 2048 and bits <= 4096 <- bit_size(strip_zeros(nb)) do
      {:ok, [eb, nb]}
    else
      _ -> :error
    end
  end

  defp rsa_key(_), do: :error

  defp strip_zeros(<<0, rest::binary>>), do: strip_zeros(rest)
  defp strip_zeros(bin), do: bin

  @doc "RFC 7638 JWK thumbprint, SHA-256, base64url without padding."
  @spec thumbprint(map()) :: {:ok, String.t()} | :error
  def thumbprint(%{"kty" => "EC", "crv" => crv, "x" => x, "y" => y}) do
    {:ok,
     digest(
       ~s({"crv":#{JSON.encode!(crv)},"kty":"EC","x":#{JSON.encode!(x)},"y":#{JSON.encode!(y)}})
     )}
  end

  def thumbprint(%{"kty" => "RSA", "e" => e, "n" => n}) do
    {:ok, digest(~s({"e":#{JSON.encode!(e)},"kty":"RSA","n":#{JSON.encode!(n)}}))}
  end

  def thumbprint(_), do: :error

  @doc "base64url SHA-256 of `value`, as in `ath` (RFC 9449)."
  def digest(value), do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)

  def b64url_decode(value) when is_binary(value) do
    if String.ends_with?(value, "=") do
      :error
    else
      Base.url_decode64(value, padding: false)
    end
  end

  def b64url_decode(_), do: :error
end
