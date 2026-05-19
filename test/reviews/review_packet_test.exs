defmodule Reviews.ReviewPacketTest do
  use ExUnit.Case, async: true

  alias Reviews.ReviewPacket

  test "wraps canonical packet JSON with typed accessors" do
    packet =
      ReviewPacket.new(%{
        "title" => "Packet",
        "summary" => "Read first.",
        "sections" => [
          %{
            "title" => "Walkthrough",
            "rows" => [
              %{"kind" => "markdown", "body" => "Start here."},
              %{"kind" => "hunk", "path" => "lib/foo.ex", "hunk_index" => 1}
            ]
          }
        ]
      })

    assert ReviewPacket.present?(packet)
    assert ReviewPacket.text(packet, "title") == "Packet"
    assert ReviewPacket.text(packet, "summary") == "Read first."
    assert [%{title: "Walkthrough", rows: rows}] = ReviewPacket.sections(packet)
    assert [%{"kind" => "markdown"}, %{"kind" => "hunk"}] = rows
  end

  test "supports locally-built atom-key packet maps without arbitrary atom creation" do
    packet = %{
      title: "Packet",
      sections: [
        %{
          title: "Smoke",
          rows: [
            %{kind: "markdown", body: "Run smoke test"},
            "not a row"
          ]
        }
      ]
    }

    assert ReviewPacket.present?(packet)
    assert ReviewPacket.text(packet, "title") == "Packet"
    assert [%{title: "Smoke", rows: [%{body: "Run smoke test"}]}] = ReviewPacket.sections(packet)
    assert ReviewPacket.text(%{body: "Run smoke test"}, "body") == "Run smoke test"
  end

  test "handles nil and malformed packet values as empty packets" do
    refute ReviewPacket.present?(nil)
    refute ReviewPacket.present?(%{})
    assert ReviewPacket.text(%{"title" => ["not", "text"]}, "title") == ""
    assert ReviewPacket.rows(%{"sections" => "not rows"}, "sections") == []
  end
end
