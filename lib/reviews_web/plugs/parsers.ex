defmodule ReviewsWeb.Plugs.Parsers do
  @moduledoc """
  `Plug.Parsers` with a smaller body limit for `/mcp` and `/oauth`.

  CLI pushes send whole diffs as JSON, so the API keeps a large limit. MCP
  requests get their own limit, enforced while the body is read and before
  JSON decoding, so an oversized MCP request fails with 413 without being
  buffered in full.
  """
  @behaviour Plug

  @impl true
  def init(opts) do
    {mcp_length, opts} = Keyword.pop!(opts, :mcp_length)

    %{
      default: Plug.Parsers.init(opts),
      mcp: Plug.Parsers.init(Keyword.put(opts, :length, mcp_length))
    }
  end

  @impl true
  def call(%Plug.Conn{path_info: ["mcp" | _]} = conn, %{mcp: opts}),
    do: Plug.Parsers.call(conn, opts)

  # OAuth requests are small forms and registration JSON.
  def call(%Plug.Conn{path_info: ["oauth" | _]} = conn, %{mcp: opts}),
    do: Plug.Parsers.call(conn, opts)

  def call(conn, %{default: opts}), do: Plug.Parsers.call(conn, opts)
end
