defmodule ReviewsWeb.LegalHTML do
  @moduledoc """
  The text of the Privacy Policy and the Terms of Service, in
  `legal_html/*.html.heex`.

  Both are drafts, not legal advice: the page says so in a banner, and every
  value only the operator can supply is a `placeholder/1`, which renders
  highlighted in brackets so none ships unnoticed. The Privacy Policy
  describes what the code collects; update it with any change to what
  Reviews stores, logs or shares.
  """
  use ReviewsWeb, :html

  embed_templates "legal_html/*"

  @updated "[DATE]"

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :flash, :map, required: true
  attr :current_user, :map, default: nil
  slot :inner_block, required: true

  defp legal_page(assigns) do
    assigns = assign(assigns, :updated, @updated)

    ~H"""
    <Layouts.app flash={@flash}>
      <div id={@id} class="l-page">
        <Layouts.landing_topbar current_user={@current_user} show_workflow_anchor={false} />
        <article class="legal-content">
          <header class="legal-header">
            <h1>{@title}</h1>
            <p class="legal-updated">
              Last updated:
              <.placeholder>{@updated}</.placeholder>
            </p>
          </header>
          <aside id="legal-draft" class="legal-draft" role="note">
            <strong>Draft.</strong>
            This page is a draft under review and is not legal advice. Text in highlighted
            brackets is still to be filled in.
          </aside>
          {render_slot(@inner_block)}
        </article>
        <Layouts.site_footer />
      </div>
    </Layouts.app>
    """
  end

  # Who runs the hosted service, and how to reach them.
  defp operator(assigns), do: ~H"<.placeholder>[LEGAL ENTITY NAME]</.placeholder>"
  defp contact(assigns), do: ~H"<.placeholder>[CONTACT EMAIL]</.placeholder>"

  slot :inner_block, required: true

  defp placeholder(assigns) do
    ~H"""
    <mark class="legal-placeholder">{render_slot(@inner_block)}</mark>
    """
  end
end
