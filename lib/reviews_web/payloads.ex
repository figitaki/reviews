defmodule ReviewsWeb.Payloads do
  @moduledoc "Public identity, comment and projected-thread payloads shared by API readers."

  def identity(%Reviews.Accounts.Identity{} = identity) do
    %{
      id: identity.id,
      kind: identity.kind,
      handle: identity.handle,
      username: identity.handle,
      display_name: identity.display_name,
      avatar_url: identity.avatar_url
    }
  end

  def identity(_), do: nil

  def identity(value, :compact) do
    case identity(value) do
      nil -> nil
      payload -> Map.take(payload, [:id, :kind, :handle, :display_name])
    end
  end

  def comment(comment, :compact) do
    payload =
      comment(comment) |> Map.put(:author, identity(comment.author, :compact)) |> bound_metadata()

    if is_nil(payload.attribution), do: Map.delete(payload, :attribution), else: payload
  end

  def comment(comment, :bounded), do: comment(comment) |> bound_metadata()

  defp bound_metadata(payload) do
    bounded =
      Enum.reduce([:author, :attribution], payload, fn key, acc ->
        Map.update!(acc, key, fn
          nil ->
            nil

          metadata ->
            Map.new(metadata, fn
              {key, value} when is_binary(value) -> {key, ReviewsWeb.MCP.Budget.cap(value, 512)}
              pair -> pair
            end)
        end)
      end)

    if bounded == payload, do: bounded, else: Map.put(bounded, :metadata_truncated, true)
  end

  def comment(comment) do
    %{
      id: comment.id,
      body: comment.body,
      author: identity(comment.author),
      attribution: Reviews.ReviewView.attribution_payload(comment),
      inserted_at: comment.inserted_at
    }
  end

  def thread(thread) do
    line = get_in(thread.anchor || %{}, ["line_number_hint"])

    %{
      id: thread.id,
      file_path: thread.file_path,
      path: thread.file_path,
      side: thread.side,
      line_hint: line,
      line: line,
      line_text: get_in(thread.original_anchor || %{}, ["line_text"]),
      anchor_status: thread.anchor_status,
      originating_revision: thread.originating_patchset_number,
      status: thread.status,
      author: identity(thread.author),
      resolved_by: identity(thread.resolved_by),
      resolved_at: thread.resolved_at
    }
  end
end
