defmodule ReviewsWeb.DesignSystemComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ReviewsWeb.DesignSystemComponents

  describe "ds_shell/1" do
    test "brand link keeps an accessible name when the label is hidden on narrow screens" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DesignSystemComponents.ds_shell brand="Reviews" home="/">
          <:actions><a href="/auth/github">Sign in</a></:actions>
          <p>Body</p>
        </DesignSystemComponents.ds_shell>
        """)

      # Below 480px the CSS hides `.design-brand-label` and shows only the
      # mark, so the link name must come from aria-label.
      assert html =~ ~s(aria-label="Reviews home")
      assert html =~ ~s(<span class="design-brand-label">Reviews</span>)
      assert html =~ ~s(class="ds-shell-actions")
    end

    test "brand link comes before the actions, so focus order stays the same" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DesignSystemComponents.ds_shell brand="Reviews" home="/">
          <:actions><a href="/auth/github">Sign in</a></:actions>
          <p>Body</p>
        </DesignSystemComponents.ds_shell>
        """)

      {brand_at, _} = :binary.match(html, "design-brand")
      {actions_at, _} = :binary.match(html, "ds-shell-actions")
      assert brand_at < actions_at
    end
  end
end
