defmodule ReviewsWeb.Api.ApiHelpers do
  @moduledoc """
  Shared helpers for the JSON API controllers: changeset error formatting and
  the `%{errors: %{detail: ..., code: ...}}` error envelope.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  def format_changeset(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  def error_json(conn, status, detail) do
    conn
    |> put_status(status)
    |> json(%{errors: %{detail: detail}})
  end

  def error_json(conn, status, code, detail) when is_atom(code) do
    conn
    |> put_status(status)
    |> json(%{errors: %{detail: detail, code: Atom.to_string(code)}})
  end
end
