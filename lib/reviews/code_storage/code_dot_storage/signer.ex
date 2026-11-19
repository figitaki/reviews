defmodule Reviews.CodeStorage.CodeDotStorage.Signer do
  @moduledoc """
  Signs code.storage JWTs.

  code.storage checks each token's ES256 (P-256, SHA-256) signature against
  the public half of the organization's API key. A signer turns a claims map
  into a compact ES256 JWT, so the private key can live anywhere that can
  produce that signature.

  The signer is `:signer` under `config :reviews, Reviews.CodeStorage`. The
  default, and today the only implementation, is
  `Reviews.CodeStorage.CodeDotStorage.PemSigner`.
  """

  @doc """
  Signs `claims` and returns a compact ES256 JWT. `config` is the
  `Reviews.CodeStorage` config. Return `{:error, :code_storage_misconfigured}`
  when the signer has no key to sign with.
  """
  @callback sign(claims :: map(), config :: keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc "The configured signer module."
  def impl(config), do: config[:signer] || Reviews.CodeStorage.CodeDotStorage.PemSigner
end
