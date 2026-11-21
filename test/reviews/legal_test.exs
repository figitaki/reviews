defmodule Reviews.LegalTest do
  use ExUnit.Case, async: true

  alias Reviews.Legal

  @shared %{operator_name: "Op", contact_email: "a@b.c", updated: "2026-11-21"}
  @privacy Map.merge(@shared, %{
             hosting_region: "Canada",
             log_retention: "30 days",
             backup_retention: "7 days"
           })
  @terms Map.merge(@shared, %{governing_law: "Ontario", venue: "Toronto", liability_cap: "C$100"})

  test "nothing configured means no documents" do
    assert Legal.document(:privacy, %{}) == nil
    assert Legal.document(:terms, %{}) == nil
  end

  test "a complete template is used, with only its own fields" do
    assert {:template, fields} = Legal.document(:privacy, Map.merge(@privacy, @terms))
    assert fields.hosting_region == "Canada"
    refute Map.has_key?(fields, :venue)
  end

  test "a URL wins over the template, per document" do
    config = Map.merge(@privacy, %{terms_url: "https://op.example/terms", venue: "Toronto"})

    assert Legal.document(:terms, config) == {:url, "https://op.example/terms"}
    assert {:template, _} = Legal.document(:privacy, config)
  end

  test "shared fields alone do not turn a document on" do
    assert Legal.document(:terms, @privacy) == nil
  end

  test "a partly filled template names the missing variables" do
    config = %{@terms | operator_name: "  "} |> Map.delete(:venue)

    assert Legal.document(:terms, config) ==
             {:error, ["LEGAL_OPERATOR_NAME", "LEGAL_VENUE"]}
  end
end
