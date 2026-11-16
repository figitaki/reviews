defmodule Reviews.OAuth.Issuer do
  @moduledoc """
  The name of the gatekeep issuer, and the process that holds its client
  metadata cache. Start it after `Reviews.Repo`.

  Its config comes from `Reviews.OAuth.config/0`, not from
  `config :reviews, Reviews.OAuth.Issuer`: gatekeep reads an issuer's config
  from the application environment as literal values, and Reviews' issuer
  and resource identifiers default to the endpoint's public URL at runtime.
  So call `Reviews.OAuth` functions, or `Gatekeep` functions with
  `Reviews.OAuth.config/0`, rather than this module's `config/0`,
  `list_grants/1`, or `revoke_grant/1`.
  """
  use Gatekeep, otp_app: :reviews
end
