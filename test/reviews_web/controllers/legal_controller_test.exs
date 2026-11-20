defmodule ReviewsWeb.LegalControllerTest do
  use ReviewsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  for {path, id, title} <- [
        {"/privacy", "privacy", "Privacy Policy"},
        {"/terms", "terms", "Terms of Service"}
      ] do
    test "#{path} is a public draft with its placeholders visible", %{conn: conn} do
      doc = conn |> get(unquote(path)) |> html_response(200) |> LazyHTML.from_document()

      assert doc |> LazyHTML.query("##{unquote(id)} h1") |> LazyHTML.text() == unquote(title)
      assert doc |> LazyHTML.query("#legal-draft") |> LazyHTML.text() =~ "not legal advice"

      placeholders = doc |> LazyHTML.query("mark.legal-placeholder") |> Enum.map(&LazyHTML.text/1)
      assert "[LEGAL ENTITY NAME]" in placeholders
      assert "[CONTACT EMAIL]" in placeholders

      # Each page links the other from its footer.
      assert doc |> LazyHTML.query("#footer-privacy[href='/privacy']") |> Enum.any?()
      assert doc |> LazyHTML.query("#footer-terms[href='/terms']") |> Enum.any?()
    end
  end

  test "the privacy policy states that review links are public and code storage is off", %{
    conn: conn
  } do
    text = conn |> get(~p"/privacy") |> html_response(200) |> LazyHTML.from_document()

    assert text |> LazyHTML.query("#privacy-visibility") |> LazyHTML.text() =~
             "anyone with the URL can read the review"

    assert text |> LazyHTML.query("#privacy-collect") |> LazyHTML.text() =~
             "It is not turned on for the hosted service."
  end

  test "the terms leave governing law to the operator", %{conn: conn} do
    doc = conn |> get(~p"/terms") |> html_response(200) |> LazyHTML.from_document()

    placeholders =
      doc |> LazyHTML.query("#terms-law mark.legal-placeholder") |> Enum.map(&LazyHTML.text/1)

    assert placeholders == ["[GOVERNING LAW]", "[VENUE]"]
  end

  test "the landing page footer links both pages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#site-footer #footer-privacy[href='/privacy']")
    assert has_element?(view, "#site-footer #footer-terms[href='/terms']")
  end

  test "the signed-out review list and Settings link the terms under sign-in", %{conn: conn} do
    for {path, id} <- [
          {~p"/reviews", "reviews-sign-in-legal"},
          {~p"/settings", "settings-sign-in-legal"}
        ] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "##{id} a[href='/terms']", "Terms of Service")
      assert has_element?(view, "##{id} a[href='/privacy']", "Privacy Policy")
    end
  end
end
