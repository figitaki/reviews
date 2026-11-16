defmodule ReviewsWeb.AuthRelayGithubOAuth do
  @moduledoc """
  OAuth2 module for the relay's `:github_relay` Ueberauth provider.

  The relay signs in with the preview GitHub OAuth app, whose one callback URL
  is the relay's `/auth/relay/github/callback`, not with the app's own GitHub
  OAuth app. This passes the relay credentials (`AUTH_RELAY_GITHUB_CLIENT_ID`
  and `AUTH_RELAY_GITHUB_CLIENT_SECRET`) to `Ueberauth.Strategy.Github.OAuth`
  for the authorize URL and the token exchange.

  `Ueberauth.Strategy.Github.OAuth.client/1` still checks that the app's own
  GitHub OAuth config is set, and the strategy fetches the profile with the
  access token through it. The relay runs on production, which has that config.
  """
  alias Ueberauth.Strategy.Github.OAuth

  def authorize_url!(params \\ [], opts \\ []),
    do: OAuth.authorize_url!(params, Keyword.merge(opts, credentials()))

  def get_token!(params \\ [], _options \\ []),
    do: OAuth.get_token!(params, options: [client_options: credentials()])

  defp credentials do
    config = Application.get_env(:reviews, :auth_relay, [])
    [client_id: config[:github_client_id], client_secret: config[:github_client_secret]]
  end
end
