defmodule Reviews.ReviewPacket do
  @moduledoc """
  Typed read wrapper around the canonical packet JSON map.

  Packets are persisted and transported as JSON maps, but rendering and
  navigation should go through this module instead of open-coded map access.
  """

  defstruct data: %{}

  @type t :: %__MODULE__{data: map()}

  @text_keys ~w(
    title
    summary
    testing_instructions
  )

  @row_keys ~w(
    invariants
    tour
    tasks
    rollout
    open_questions
  )

  @atom_key_names @text_keys ++ @row_keys ++ ~w(
    body
    description
    format_version
    key
    kind
    path
  )
  @atom_keys Map.new(@atom_key_names, fn key -> {key, String.to_atom(key)} end)

  def new(%__MODULE__{} = packet), do: packet
  def new(packet) when is_map(packet), do: %__MODULE__{data: packet}
  def new(_), do: %__MODULE__{data: %{}}

  def present?(packet) do
    packet = new(packet)

    Enum.any?(@text_keys, &(text(packet, &1) != "")) ||
      Enum.any?(@row_keys, &(rows(packet, &1) != []))
  end

  def text(packet, key) when is_binary(key) do
    packet = new(packet)

    case get(packet, key) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _ -> ""
    end
  end

  def rows(packet, key) when is_binary(key) do
    packet = new(packet)

    case get(packet, key) do
      rows when is_list(rows) -> Enum.filter(rows, &is_map/1)
      _ -> []
    end
  end

  def raw(%__MODULE__{data: data}), do: data
  def raw(packet) when is_map(packet), do: packet
  def raw(_), do: %{}

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
