defmodule ReviewsWeb.LegalHTML do
  @moduledoc """
  The built-in Privacy Policy and Terms of Service templates, in
  `legal_html/*.html.heex`, filled in from the deployment's config
  (`Reviews.Legal`, `@legal`). They are a starting point for an operator,
  not legal advice.

  The Privacy Policy describes what the code collects. Parts that depend on
  how the deployment is set up, such as code storage, the hosted MCP
  endpoint, the aggregate export and the preview sign-in relay, show only
  when that feature is on. Update the template with any change to what
  Reviews stores, logs or shares.
  """
  use ReviewsWeb, :html

  embed_templates "legal_html/*"

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :legal, :map, required: true
  attr :flash, :map, required: true
  attr :current_user, :map, default: nil
  slot :inner_block, required: true

  defp legal_page(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id={@id} class="l-page">
        <Layouts.landing_topbar current_user={@current_user} show_workflow_anchor={false} />
        <article class="legal-content">
          <header class="legal-header">
            <h1>{@title}</h1>
            <p class="legal-updated">Last updated: {@legal.updated}</p>
          </header>
          {render_slot(@inner_block)}
        </article>
        <Layouts.site_footer />
      </div>
    </Layouts.app>
    """
  end

  attr :legal, :map, required: true

  defp contact(assigns) do
    ~H"""
    <a href={"mailto:" <> @legal.contact_email}>{@legal.contact_email}</a>
    """
  end

  defp host, do: ReviewsWeb.Endpoint.host()

  # Features that change what the Privacy Policy says.
  defp code_storage?, do: Reviews.CodeStorage.enabled?()
  defp mcp?, do: Reviews.MCPAuth.enabled?()
  defp relay?, do: Reviews.AuthRelay.relay?()
  defp aggregate_export?, do: match?({:ok, _}, Reviews.Analytics.Credential.configured_digest())
  defp connectors, do: Enum.map(Reviews.MCPAuth.connectors(), & &1.name)
end
