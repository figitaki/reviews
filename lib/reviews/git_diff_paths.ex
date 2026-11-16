defmodule Reviews.GitDiffPaths do
  @moduledoc false

  # Git C-quotes control characters and (by default) non-ASCII path bytes.
  # Decode bytes before checking UTF-8, since octal escapes form whole codepoints.
  def parse(header) do
    with {:ok, "a/" <> old, rest} <- old_path(header),
         {:ok, "b/" <> new, ""} <- new_path(rest),
         true <- String.valid?(old) and String.valid?(new) do
      {:ok, old, new}
    else
      _ -> :error
    end
  end

  defp old_path("\"" <> rest) do
    with {:ok, path, " " <> tail} <- unquote_path(rest, []) do
      {:ok, path, tail}
    else
      _ -> :error
    end
  end

  defp old_path(header) do
    case :binary.match(header, [" b/", " \"b/"]) do
      {offset, _} ->
        <<path::binary-size(^offset), " ", rest::binary>> = header
        {:ok, path, rest}

      :nomatch ->
        :error
    end
  end

  defp new_path("\"" <> rest), do: unquote_path(rest, [])
  defp new_path(path), do: {:ok, path, ""}

  defp unquote_path("\"" <> rest, bytes),
    do: {:ok, bytes |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp unquote_path(<<?\\, a, b, c, rest::binary>>, bytes)
       when a in ?0..?3 and b in ?0..?7 and c in ?0..?7 do
    unquote_path(rest, [(a - ?0) * 64 + (b - ?0) * 8 + c - ?0 | bytes])
  end

  @escapes %{
    ?a => 7,
    ?b => 8,
    ?t => 9,
    ?n => 10,
    ?v => 11,
    ?f => 12,
    ?r => 13,
    ?\\ => ?\\,
    ?" => ?"
  }
  defp unquote_path(<<?\\, escape, rest::binary>>, bytes) do
    case @escapes do
      %{^escape => byte} -> unquote_path(rest, [byte | bytes])
      _ -> :error
    end
  end

  defp unquote_path(<<byte, rest::binary>>, bytes), do: unquote_path(rest, [byte | bytes])
  defp unquote_path("", _bytes), do: :error
end
