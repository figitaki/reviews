defmodule Reviews.Errors do
  @moduledoc """
  The error vocabulary every surface shares. A domain function returns
  `{:error, reason}`; `code/1` turns the reason into a stable code, and each
  code has one HTTP status and one safe default detail. REST and Poppy send
  the code as `error_code` (`ReviewsWeb.ApiErrors`), and MCP sends it as
  `structuredContent.error.code`, so a client handles one list of codes.

  Unknown reasons become `:write_failed`, so no internal reason or database
  text reaches a client.
  """

  @errors %{
    unauthorized: {401, "Sign in to do this."},
    # Poppy 1.0 protocol errors (spec section 7), sent by `PoppyAuth`.
    invalid_session: {400, "invalid_session"},
    session_ended: {400, "session_ended"},
    version_unsupported: {400, "version_unsupported"},
    invalid_token: {401, "invalid_token"},
    invalid_dpop_proof: {401, "invalid_dpop_proof"},
    insufficient_scope: {403, "insufficient_scope"},
    forbidden: {403, "You cannot do that on this review."},
    review_not_found: {404, "Review not found"},
    patchset_not_found: {404, "Patchset not found"},
    thread_not_found: {404, "Thread not found"},
    section_not_found: {404, "Section not found"},
    invalid_request: {400, "Invalid request"},
    invalid_section_index: {400, "Invalid section index"},
    invalid_pagination: {422, "Invalid pagination parameters"},
    invalid_status: {422, "Invalid status"},
    invalid_anchor: {422, "The anchor is not in the selected revision's diff"},
    invalid_side: {422, "side must be \"old\" or \"new\""},
    invalid_file_path: {422, "file_path is required"},
    unknown_granularity: {422, "anchor granularity must be \"line\" or \"token_range\""},
    empty_body: {422, "body cannot be empty"},
    invalid_packet: {422, "Invalid packet"},
    validation_failed: {422, "Invalid input"},
    rate_limited: {429, "Too many requests. Retry later."},
    write_failed: {422, "The write failed. Nothing was saved."}
  }

  # Domain reasons that name the same problem as a code.
  @aliases %{
    invalid_cursor: :invalid_pagination,
    invalid_page_size: :invalid_pagination,
    could_not_publish: :write_failed
  }

  @by_name Map.new(Map.keys(@errors), &{Atom.to_string(&1), &1})

  @type code :: atom()

  @doc "Every code, for documentation and tests."
  def codes, do: Map.keys(@errors)

  @doc "The stable code for a domain error reason or changeset."
  @spec code(term()) :: code()
  def code(%Ecto.Changeset{} = changeset), do: changeset_code(changeset)
  def code(reason) when is_map_key(@errors, reason), do: reason
  def code(reason) when is_map_key(@aliases, reason), do: Map.fetch!(@aliases, reason)
  # A code already given as a string, such as a protocol error name.
  def code(reason) when is_map_key(@by_name, reason), do: Map.fetch!(@by_name, reason)
  def code(_reason), do: :write_failed

  @doc "The HTTP status for a code (or a reason, mapped through `code/1`)."
  def status(reason), do: reason |> code() |> then(&elem(Map.fetch!(@errors, &1), 0))

  @doc "A safe default detail for a code (or a reason)."
  def detail(reason), do: reason |> code() |> then(&elem(Map.fetch!(@errors, &1), 1))

  # Packet validation (#188) tags its changeset errors with `code:
  # "invalid_packet.<problem>"`; every other changeset is plain validation.
  defp changeset_code(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {_message, opts} -> opts[:code] end)
    |> Map.values()
    |> List.flatten()
    |> Enum.any?(&(is_binary(&1) and String.starts_with?(&1, "invalid_packet")))
    |> if(do: :invalid_packet, else: :validation_failed)
  end
end
