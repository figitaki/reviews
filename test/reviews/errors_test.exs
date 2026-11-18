defmodule Reviews.ErrorsTest do
  use ExUnit.Case, async: true

  alias Reviews.Errors

  test "reasons map to one stable code with one status" do
    assert Errors.code(:thread_not_found) == :thread_not_found
    assert Errors.status(:thread_not_found) == 404
    assert Errors.code(:invalid_cursor) == :invalid_pagination
    assert Errors.code(:invalid_page_size) == :invalid_pagination
    assert Errors.status(:invalid_cursor) == 422
    assert Errors.code("insufficient_scope") == :insufficient_scope
    assert Errors.status("insufficient_scope") == 403
  end

  test "unknown reasons never reach a client as codes" do
    assert Errors.code(:some_internal_reason) == :write_failed
    assert Errors.code("not_a_code") == :write_failed
    assert Errors.code({:postgrex, "relation comments"}) == :write_failed
    assert Errors.detail(:some_internal_reason) == "The write failed. Nothing was saved."
  end

  test "packet validation changesets get their own code" do
    types = %{packet: :map, title: :string}
    base = Ecto.Changeset.change({%{}, types})

    packet =
      Ecto.Changeset.add_error(base, :packet, "misses lib/a.ex hunk 1",
        code: "invalid_packet.uncovered_change"
      )

    plain = Ecto.Changeset.add_error(base, :title, "can't be blank", validation: :required)

    assert Errors.code(packet) == :invalid_packet
    assert Errors.code(plain) == :validation_failed
    assert Errors.status(packet) == 422
  end
end
