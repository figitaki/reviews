defmodule ReviewsWeb.LegalControllerTest do
  # Changes the :legal application env, so tests here run alone.
  use ReviewsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous = Application.get_env(:reviews, :legal)
    on_exit(fn -> Application.put_env(:reviews, :legal, previous) end)
    :ok
  end

  defp doc(conn, path), do: conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

  defp text(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp hrefs(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute("href")

  describe "with the built-in templates (config/test.exs)" do
    test "the privacy policy is filled in from config", %{conn: conn} do
      doc = doc(conn, ~p"/privacy")

      assert text(doc, "#privacy h1") == "Privacy Policy"
      assert text(doc, ".legal-updated") =~ "2026-11-21"
      assert text(doc, "#privacy") =~ "operated by Example Operator LLC"
      assert text(doc, "#privacy") =~ ReviewsWeb.Endpoint.host()
      assert text(doc, "#privacy-retention") =~ "Request logs: 30 days."
      assert text(doc, "#privacy-retention") =~ "Database backups: 7 days."
      assert text(doc, "#privacy-transfers") =~ "the European Union"
      assert "mailto:privacy@example.com" in hrefs(doc, "#privacy-contact a")

      assert text(doc, "#privacy-visibility") =~ "anyone with the URL can read the review"
      # Code storage is off in tests, so the policy does not mention it.
      refute text(doc, "#privacy") =~ "code.storage"
      refute text(doc, "#privacy") =~ "["
    end

    test "the terms are filled in from config", %{conn: conn} do
      doc = doc(conn, ~p"/terms")

      assert text(doc, "#terms-law") =~ "laws of the State of Example"
      assert text(doc, "#terms-law") =~ "courts of Example County"
      assert text(doc, "#terms-liability") =~ "US$50"
      assert hrefs(doc, "#terms-privacy a") == ["/privacy"]
      refute text(doc, "#terms") =~ "["
    end

    test "the footer and every sign-in link both pages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#site-footer #footer-privacy[href='/privacy']")
      assert has_element?(view, "#site-footer #footer-terms[href='/terms']")

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

  describe "with the operator's own policies" do
    setup do
      Application.put_env(:reviews, :legal,
        privacy_url: "https://op.example/privacy",
        terms_url: "https://op.example/terms"
      )
    end

    test "the pages redirect and every link goes there", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/privacy")) == "https://op.example/privacy"
      assert redirected_to(get(conn, ~p"/terms")) == "https://op.example/terms"

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#footer-privacy[href='https://op.example/privacy']")

      doc = doc(conn, ~p"/device")

      assert hrefs(doc, "#device-sign-in-legal a") == [
               "https://op.example/terms",
               "https://op.example/privacy"
             ]
    end
  end

  describe "with terms but no privacy policy" do
    setup do
      Application.put_env(:reviews, :legal, terms_url: "https://op.example/terms")
    end

    test "the notice names only the terms", %{conn: conn} do
      doc = doc(conn, ~p"/device")

      assert text(doc, "#device-sign-in-legal") =~ "you agree to the Terms of Service."
      refute text(doc, "#device-sign-in-legal") =~ "Privacy"
      assert get(conn, ~p"/privacy").status == 404
    end
  end

  describe "with nothing configured" do
    setup do
      Application.put_env(:reviews, :legal, [])
    end

    test "there are no legal pages, links or agreement lines", %{conn: conn} do
      assert get(conn, ~p"/privacy").status == 404
      assert get(conn, ~p"/terms").status == 404

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#site-footer")
      refute has_element?(view, "#footer-privacy")
      refute has_element?(view, "#footer-terms")

      {:ok, view, _html} = live(conn, ~p"/reviews")
      assert has_element?(view, "#reviews-sign-in")
      refute has_element?(view, "#reviews-sign-in-legal")

      doc = doc(conn, ~p"/device")
      assert doc |> LazyHTML.query("#device-sign-in") |> Enum.any?()
      refute doc |> LazyHTML.query("#device-sign-in-legal") |> Enum.any?()
    end
  end

  test "a partly filled template stops the boot" do
    Application.put_env(:reviews, :legal, operator_name: "Op", governing_law: "Ontario")

    error = assert_raise ArgumentError, &Reviews.Legal.validate!/0
    assert error.message =~ "LEGAL_CONTACT_EMAIL"
    assert error.message =~ "LEGAL_TERMS_URL"
  end
end
