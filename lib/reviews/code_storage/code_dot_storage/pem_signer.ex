defmodule Reviews.CodeStorage.CodeDotStorage.PemSigner do
  @moduledoc """
  Signs code.storage JWTs with the P-256 private key in `:jwt_private_key`
  (PKCS8 PEM, from `CODE_STORAGE_JWT_PRIVATE_KEY`).
  """
  @behaviour Reviews.CodeStorage.CodeDotStorage.Signer

  @impl true
  def sign(claims, config) do
    case config[:jwt_private_key] do
      nil -> {:error, :code_storage_misconfigured}
      pem -> sign_with_pem(claims, pem)
    end
  end

  defp sign_with_pem(claims, pem) do
    signer = Joken.Signer.create("ES256", %{"pem" => pem})

    case Joken.Signer.sign(claims, signer) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, {:jwt_signing_failed, reason}}
    end
  rescue
    # An unusable PEM raises inside Joken/JOSE; report it as a result instead.
    error -> {:error, {:jwt_signing_failed, error.__struct__}}
  end
end
