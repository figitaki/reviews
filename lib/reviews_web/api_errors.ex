defmodule ReviewsWeb.ApiErrors do
  @moduledoc "Stable error codes added alongside legacy REST and Poppy response fields."

  @codes ~w(review_not_found thread_not_found patchset_not_found section_not_found forbidden unauthorized invalid_request invalid_status invalid_section_index invalid_anchor invalid_side invalid_file_path empty_body unknown_granularity write_failed validation_failed)a

  def code(%Ecto.Changeset{}), do: :validation_failed
  def code(reason) when reason in @codes, do: reason
  def code(_), do: :write_failed

  def detail(code, message), do: payload(code, message, %{errors: %{detail: message}})

  def payload(code, message, legacy) do
    Map.merge(legacy, %{error_code: to_string(code), error_detail: message})
  end

  def changeset(changeset) do
    fields = Ecto.Changeset.traverse_errors(changeset, &message/1)
    payload(:validation_failed, "Invalid input", %{errors: fields})
  end

  defp message({msg, opts}) do
    Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
