defmodule Reviews.Paging do
  @moduledoc """
  Page limits and cursors for every paged read: the MCP tools today, and the
  REST and Poppy page endpoints. Surfaces call this module instead of keeping
  their own cursor grammar and limits, so a cursor means the same thing
  everywhere.

  A cursor is `<phase><a>.<b>.<tag>`, such as `"c42.0.123456789"`:

    * `phase` is one lowercase letter naming what the position counts
      (`:position` for plain lists; `get_review` also uses `:fields`,
      `:sections`, and `:revisions`).
    * `a` and `b` are the position, such as an item ID and a byte offset.
    * `tag` binds the cursor to the query it continues: the read, review,
      revision, and filters. `decode/2` refuses a cursor from another query,
      so a cursor from one thread, filter, or revision cannot silently skip
      or repeat items of another.

  Cursors start with a letter and contain only digits and dots after it, so
  no client parses one as a number and schemas can describe them simply.
  Clients must treat them as opaque.
  """

  @default_max_bytes 40_000
  @min_max_bytes 2_000
  @max_bytes_limit 120_000
  @default_limit 25
  @max_limit 100

  @phases %{position: "c", fields: "f", sections: "s", revisions: "r"}
  @phase_letters Map.new(@phases, fn {phase, letter} -> {letter, phase} end)
  @tag_range 1_000_000_000

  @type phase :: :position | :fields | :sections | :revisions
  @type position :: {phase(), non_neg_integer(), non_neg_integer()}

  def default_max_bytes, do: @default_max_bytes
  def min_max_bytes, do: @min_max_bytes
  def max_bytes_limit, do: @max_bytes_limit
  def default_limit, do: @default_limit
  def max_limit, do: @max_limit

  @doc """
  The `max_bytes` a request asked for, or the default when it asked for none.
  Accepts an integer or a decimal string (query parameters).
  """
  def max_bytes(value), do: bounded(value, @default_max_bytes, @min_max_bytes, @max_bytes_limit)

  @doc "The item `limit` a request asked for, or the default. Same inputs as `max_bytes/1`."
  def limit(value), do: bounded(value, @default_limit, 1, @max_limit)

  defp bounded(nil, default, _min, _max), do: {:ok, default}
  defp bounded(n, _default, min, max) when is_integer(n) and n >= min and n <= max, do: {:ok, n}

  defp bounded(value, default, min, max) when is_binary(value) and byte_size(value) <= 18 do
    case Integer.parse(value) do
      {n, ""} -> bounded(n, default, min, max)
      _ -> {:error, :invalid_page_size}
    end
  end

  defp bounded(_value, _default, _min, _max), do: {:error, :invalid_page_size}

  @doc """
  The cursor for `position` within the query `scope`, or nil when there is no
  next page. `scope` is any term naming the query, such as
  `{:threads, review.id, revision, status, path}`.
  """
  @spec encode(term(), position() | nil) :: String.t() | nil
  def encode(_scope, nil), do: nil

  def encode(scope, {phase, a, b})
      when is_map_key(@phases, phase) and is_integer(a) and a >= 0 and is_integer(b) and b >= 0 do
    "#{Map.fetch!(@phases, phase)}#{a}.#{b}.#{tag(scope)}"
  end

  @doc """
  The position in `cursor`, `{:ok, nil}` without one, or
  `{:error, :invalid_cursor}` when it is malformed or belongs to another query.
  """
  @spec decode(term(), term()) :: {:ok, position() | nil} | {:error, :invalid_cursor}
  def decode(nil, _scope), do: {:ok, nil}

  def decode(cursor, scope) when is_binary(cursor) and byte_size(cursor) <= 64 do
    expected = Integer.to_string(tag(scope))

    with [_, letter, a, b, ^expected] <-
           Regex.run(~r/\A([a-z])(\d{1,18})\.(\d{1,18})\.(\d{1,10})\z/, cursor),
         {:ok, phase} <- Map.fetch(@phase_letters, letter) do
      {:ok, {phase, String.to_integer(a), String.to_integer(b)}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def decode(_cursor, _scope), do: {:error, :invalid_cursor}

  # Binds a cursor to its query; it is not a secret. `phash2` is stable across
  # nodes and releases, so cursors survive a deploy.
  defp tag(scope), do: :erlang.phash2(scope, @tag_range)
end
