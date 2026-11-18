defmodule ReviewsWeb.DesignSystemComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ReviewsWeb.DesignSystemComponents

  defp render_shell do
    assigns = %{}

    ~H"""
    <DesignSystemComponents.ds_shell brand="Reviews" home="/">
      <:actions><a href="/auth/github">Sign in</a></:actions>
      <p>Body</p>
    </DesignSystemComponents.ds_shell>
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  describe "ds_shell/1" do
    test "brand link keeps an accessible name when the label is hidden on narrow screens" do
      doc = render_shell()

      # Below 480px the CSS hides `.design-brand-label` and shows only the
      # mark, so the link name must come from aria-label.
      brand =
        LazyHTML.query(doc, ~s(.ds-shell-topbar > a.design-brand[aria-label="Reviews home"]))

      assert Enum.count(brand) == 1
      assert LazyHTML.query(brand, ".design-brand-mark[aria-hidden=true]") |> Enum.count() == 1
      assert LazyHTML.query(brand, ".design-brand-label") |> LazyHTML.text() == "Reviews"
    end

    test "brand link comes before the actions, so focus order stays the same" do
      classes =
        render_shell()
        |> LazyHTML.query(".ds-shell-topbar > *")
        |> LazyHTML.attribute("class")

      assert classes == ["design-brand", "ds-shell-actions"]
    end
  end
end
