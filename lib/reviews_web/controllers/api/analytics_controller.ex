defmodule ReviewsWeb.Api.AnalyticsController do
  use ReviewsWeb, :controller
  alias Reviews.Analytics
  alias Reviews.Analytics.Credential
  action_fallback ReviewsWeb.Api.AnalyticsFallbackController

  def show(%{assigns: %{analytics_export_digest: digest}} = conn, _params) do
    with true <- Credential.current?(digest),
         {:ok, snapshot} <- Analytics.cached_snapshot(),
         true <- Credential.current?(digest) do
      json(conn, snapshot)
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  def show(_conn, _params), do: {:error, :unauthorized}
end
