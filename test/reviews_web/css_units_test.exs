defmodule ReviewsWeb.CSSUnitsTest do
  # Text and the space around it follow the reader's browser font size, so
  # sizes are rem. A px font size or space token stops growing with the rest.
  use ExUnit.Case, async: true

  @css Path.wildcard(Path.expand("../../assets/css/*.css", __DIR__))

  test "font sizes in the stylesheets are not px" do
    offenders =
      for path <- @css,
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/font-size:[^;]*\d+px/,
          do: "#{Path.basename(path)}:#{n}: #{String.trim(line)}"

    assert offenders == []
  end

  test "space, radius, font-size and control tokens are rem" do
    tokens = File.read!(Path.expand("../../assets/css/tokens.css", __DIR__))

    px_tokens =
      ~r/^\s*(--(?:space|radius|font-size|size)-[a-z0-9-]+):\s*[^;]*\d+px/m
      |> Regex.scan(tokens, capture: :all_but_first)
      |> List.flatten()

    # --radius-pill is a shape (fully round), not a size.
    assert px_tokens -- ["--radius-pill"] == []
  end
end
