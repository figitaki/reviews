defmodule Reviews.ReviewPacket do
  @moduledoc """
  Typed read wrapper around the canonical packet JSON map.

  The current packet shape is title, summary, and narrative sections. Each
  section owns ordered rows so prose and diff slices can be interleaved.
  """

  defstruct data: %{}

  @type t :: %__MODULE__{data: map()}

  @text_keys ~w(title summary)
  @row_keys ~w(sections rows)
  @atom_key_names @text_keys ++ @row_keys ++ ~w(
    body
    format_version
    hunk_index
    kind
    line_end
    line_start
    path
  )
  @atom_keys Map.new(@atom_key_names, fn key -> {key, String.to_atom(key)} end)

  def new(%__MODULE__{} = packet), do: packet
  def new(packet) when is_map(packet), do: %__MODULE__{data: packet}
  def new(_), do: %__MODULE__{data: %{}}

  def present?(packet) do
    packet = new(packet)

    Enum.any?(@text_keys, &(text(packet, &1) != "")) ||
      sections(packet) != []
  end

  def text(packet, key) when is_binary(key) do
    packet = new(packet)

    case get(packet, key) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _ -> ""
    end
  end

  def int(packet, key) when is_binary(key) do
    packet = new(packet)

    case get(packet, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def rows(packet, key) when is_binary(key) do
    packet = new(packet)

    case get(packet, key) do
      rows when is_list(rows) -> Enum.filter(rows, &is_map/1)
      _ -> []
    end
  end

  def sections(packet) do
    packet
    |> rows("sections")
    |> Enum.with_index()
    |> Enum.map(fn {section, index} ->
      %{
        index: index,
        title: text(section, "title"),
        fingerprint: section_fingerprint(section, index),
        refs: section_refs(section),
        rows: rows(section, "rows")
      }
    end)
  end

  def section_at(packet, index) when is_integer(index) do
    packet
    |> sections()
    |> Enum.find(&(&1.index == index))
  end

  def raw(%__MODULE__{data: data}), do: data
  def raw(packet) when is_map(packet), do: packet
  def raw(_), do: %{}

  def section_fingerprint(section, index) do
    title = section |> text("title") |> normalize_title()
    refs = section |> section_refs() |> Enum.join("|")

    :crypto.hash(:sha256, "#{title}\n#{refs}\n#{index}")
    |> Base.encode16(case: :lower)
  end

  def normalize_title(title) do
    title
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  def section_refs(section) when is_map(section) do
    section
    |> rows("rows")
    |> Enum.filter(&(text(&1, "kind") == "hunk"))
    |> Enum.map(&row_ref/1)
  end

  def row_ref(row) do
    path = text(row, "path")
    hunk_index = int(row, "hunk_index")
    line_start = int(row, "line_start")
    line_end = int(row, "line_end")

    cond do
      path == "" or is_nil(hunk_index) ->
        ""

      line_start && line_end ->
        "#{path}##{hunk_index}:L#{line_start}-L#{line_end}"

      true ->
        "#{path}##{hunk_index}"
    end
  end

  defp get(%__MODULE__{data: data}, key) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        value

      :error ->
        with {:ok, atom_key} <- Map.fetch(@atom_keys, key),
             {:ok, value} <- Map.fetch(data, atom_key) do
          value
        else
          _ -> nil
        end
    end
  end
end
