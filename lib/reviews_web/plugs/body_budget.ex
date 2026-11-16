defmodule ReviewsWeb.Plugs.BodyBudget do
  @moduledoc "Authenticates API writes before parsing and bounds actual body reads."
  alias ReviewsWeb.Plugs.{RequestBudget, RequireApiToken}

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = authenticate_write(conn)

    case conn.halted do
      true -> conn
      false -> parse(conn)
    end
  end

  defp authenticate_write(conn) do
    case RequestBudget.api_write?(conn) do
      true ->
        conn = RequireApiToken.call(conn, [])

        cond do
          conn.halted -> conn
          RequestBudget.allow?(:owners, conn.assigns.current_user.id) -> conn
          true -> RequestBudget.reject(conn)
        end

      false ->
        conn
    end
  end

  defp parse(conn) do
    opts =
      Plug.Parsers.init(
        parsers: [:urlencoded, :json],
        pass: [],
        json_decoder: Phoenix.json_library(),
        length: limit(conn),
        read_length: 64_000,
        read_timeout: 5_000,
        body_reader: {__MODULE__, :read_body, []}
      )

    Plug.Parsers.call(conn, opts)
  end

  defp limit(conn) do
    limits = Application.get_env(:reviews, __MODULE__, [])

    case RequestBudget.upload?(conn) do
      true -> Keyword.get(limits, :upload_bytes, 50_000_000)
      false -> Keyword.get(limits, :small_bytes, 64_000)
    end
  end

  @doc "Reads bounded chunks; Content-Length is never the authority for the limit."
  def read_body(conn, opts), do: read_chunks(conn, Keyword.fetch!(opts, :length), [], opts)

  defp read_chunks(conn, remaining, chunks, opts) do
    opts =
      Keyword.merge(opts,
        length: min(remaining + 1, 64_000),
        read_length: min(remaining + 1, 64_000)
      )

    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] and byte_size(body) > remaining ->
        {:more, "", conn}

      {:ok, body, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([body | chunks])), conn}

      {:more, body, conn} ->
        read_chunks(conn, remaining - byte_size(body), [body | chunks], opts)

      error ->
        error
    end
  end
end
