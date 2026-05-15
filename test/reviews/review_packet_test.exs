defmodule Reviews.ReviewPacketTest do
  use ExUnit.Case, async: true

  alias Reviews.ReviewPacket

  test "wraps canonical packet JSON with typed accessors" do
    packet =
      ReviewPacket.new(%{
        "title" => "Packet",
        "summary" => "Read first.",
        "tour" => [
          %{"kind" => "markdown", "body" => "Start here."},
          %{"kind" => "hunk", "path" => "lib/foo.ex"}
        ]
      })

    assert ReviewPacket.present?(packet)
    assert ReviewPacket.text(packet, "title") == "Packet"
    assert ReviewPacket.text(packet, "summary") == "Read first."
    assert [%{"kind" => "markdown"}, %{"kind" => "hunk"}] = ReviewPacket.rows(packet, "tour")
  end

  test "supports locally-built atom-key packet maps without arbitrary atom creation" do
    packet = %{
      title: "Packet",
      tasks: [
        %{key: "smoke", description: "Run smoke test"},
        "not a task"
      ]
    }

    assert ReviewPacket.present?(packet)
    assert ReviewPacket.text(packet, "title") == "Packet"
    assert [%{key: "smoke"}] = ReviewPacket.rows(packet, "tasks")
    assert ReviewPacket.text(%{description: "Run smoke test"}, "description") == "Run smoke test"
  end

  test "handles nil and malformed packet values as empty packets" do
    refute ReviewPacket.present?(nil)
    refute ReviewPacket.present?(%{})
    assert ReviewPacket.text(%{"title" => ["not", "text"]}, "title") == ""
    assert ReviewPacket.rows(%{"tour" => "not rows"}, "tour") == []
  end
end
