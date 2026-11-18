defmodule Reviews.ExternalIdentity do
  @moduledoc """
  The contract between Reviews and a way of authenticating an agent from
  outside Reviews, such as Poppy (`Reviews.Poppy.Adapter`).

  An adapter verifies one HTTP request and resolves it to an existing Reviews
  identity through an owner-approved grant (`Reviews.OAuth.Grant`). It never
  creates identities, so actor IDs, handles, and history stay the same whichever
  way an agent authenticates. Bearer API tokens (`Reviews.Accounts`) remain a
  separate, unchanged path.

  Later adapters plug in here without changing actor IDs, such as a
  Turnkey-held key that signs delegations or DPoP proofs, or a DID verifier
  that checks proofs against the DID document's `authentication`
  relationship. Each still resolves to an owner's approval of one agent
  identity.

  Each adapter records what it verified in `attribution`, a JSON-safe map stored
  with the records the request creates. Parties an adapter can't verify are
  left out or marked as claims, so the UI never shows an unverified name or an
  unsupported delegation chain as verified.
  """

  alias Reviews.Accounts.{Identity, User}
  alias Reviews.OAuth.Grant

  @type request :: %{
          method: String.t(),
          url: String.t(),
          headers: %{optional(String.t()) => String.t()}
        }

  @type result :: %{
          identity: Identity.t() | nil,
          owner: User.t() | nil,
          grant: Grant.t() | nil,
          scopes: [String.t()],
          attribution: map()
        }

  @doc """
  Verifies `request`. A verified request without account access returns
  `identity: nil` (signed out). Errors are atoms the web layer maps to the
  adapter's protocol errors.
  """
  @callback authenticate(request(), keyword()) :: {:ok, result()} | {:error, atom()}
end
