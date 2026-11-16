defmodule Reviews.OAuth.Signer do
  @moduledoc """
  Signs JWTs the issuer mints.

  The issuer signs nothing yet: codes, access tokens, and refresh tokens are
  random values stored only as hashes. This is the interface for when it
  does, such as JWT access tokens. A signer turns a claims map into a compact
  JWS, so the private key can live anywhere that can produce the signature,
  such as a Turnkey-held key. It has the same shape as the code.storage
  signer proposed in #80.

  The signer is `:signer` under `config :reviews, Reviews.OAuth`. No
  implementation ships with Reviews.
  """

  @doc """
  Signs `claims` and returns a compact JWS. `config` is the `Reviews.OAuth`
  config. Return `{:error, :no_signing_key}` when the signer has no key to
  sign with.
  """
  @callback sign(claims :: map(), config :: keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc "The configured signer module, or nil when none is configured."
  def impl(config), do: config[:signer]
end
