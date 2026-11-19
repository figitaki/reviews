defmodule ReviewsWeb.Api.AnalyticsController do
  use ReviewsWeb, :controller
  alias Reviews.Analytics
  alias Reviews.Analytics.Credential
  alias Reviews.Principal
  alias ReviewsWeb.ApiErrors

  # Only the collector principal from `ReviewsWeb.Plugs.AggregateExport`; no other caller.
  def show(
        %{assigns: %{current_principal: %Principal{via: :aggregate_export} = principal}} = conn,
        _params
      ) do
    with true <- current?(principal),
         {:ok, snapshot} <- Analytics.cached_snapshot(),
         true <- current?(principal) do
      json(conn, snapshot)
    else
      false -> error(conn, :unauthorized)
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, _params), do: error(conn, :unauthorized)

  defp current?(%Principal{attribution: %{credential_digest: digest}}),
    do: Credential.current?(digest)

  defp error(conn, reason) do
    conn
    |> put_resp_header("retry-after", "60")
    |> ApiErrors.render(reason, detail(reason))
  end

  defp detail(:unauthorized), do: "Unauthorized"
  defp detail(:unavailable), do: "Snapshot unavailable"
  defp detail(_reason), do: nil
end
