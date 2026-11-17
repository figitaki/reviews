defmodule ReviewsWeb.ApiErrors do
  @moduledoc """
  REST and Poppy error bodies: stable `error_code`/`error_detail` fields
  alongside the legacy `errors` field. Codes, statuses and default details
  come from `Reviews.Errors`, which MCP uses too.
  """
  import Plug.Conn, only: [put_status: 2]

  alias Reviews.Errors

  defdelegate code(reason), to: Errors

  @doc """
  Sends the error for a domain `reason` with the vocabulary's status. Pass
  `message` to replace the default detail with a more specific one.
  """
  def render(conn, reason, message \\ nil)

  def render(conn, %Ecto.Changeset{} = changeset, _message) do
    conn |> put_status(Errors.status(changeset)) |> Phoenix.Controller.json(changeset(changeset))
  end

  def render(conn, reason, message) do
    conn
    |> put_status(Errors.status(reason))
    |> Phoenix.Controller.json(detail(reason, message || Errors.detail(reason)))
  end

  def detail(reason, message), do: payload(reason, message, %{errors: %{detail: message}})

  # Codes always pass through the vocabulary, so an unknown reason cannot
  # reach a client as a code.
  def payload(reason, message, legacy) do
    Map.merge(legacy, %{error_code: to_string(Errors.code(reason)), error_detail: message})
  end

  def changeset(changeset) do
    fields = Ecto.Changeset.traverse_errors(changeset, &message/1)
    payload(changeset, Errors.detail(changeset), %{errors: fields})
  end

  defp message({msg, opts}) do
    Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
