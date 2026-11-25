defmodule ReviewsWeb.ReviewLive.ReviewerComponents do
  @moduledoc """
  The review's named reviewers (`Reviews.Reviewers`) under the review header.
  Everyone with the link sees the list, including invited reviewers who have
  not signed up yet. The owner also gets a field to add a reviewer by GitHub
  login and a button to remove each one.
  """
  use ReviewsWeb, :html

  attr :reviewers, :list, required: true
  attr :can_manage, :boolean, required: true
  attr :login, :string, default: ""
  attr :id_prefix, :string, default: "", doc: "prefixes every id, for several copies on one page"

  def reviewers(assigns) do
    assigns = assign(assigns, :form, to_form(%{"login" => assigns.login}, as: :reviewer))

    ~H"""
    <section
      :if={@reviewers != [] or @can_manage}
      id={@id_prefix <> "review-reviewers"}
      class="review-reviewers"
      aria-labelledby={@id_prefix <> "review-reviewers-title"}
    >
      <h2 id={@id_prefix <> "review-reviewers-title"} class="review-reviewers-title">Reviewers</h2>
      <p
        :if={@reviewers == []}
        id={@id_prefix <> "review-reviewers-empty"}
        class="review-reviewers-empty"
      >
        Add reviewers by GitHub login. They can approve, deny or ignore sections.
      </p>
      <ul :if={@reviewers != []} class="review-reviewers-list">
        <li
          :for={reviewer <- @reviewers}
          :key={reviewer.github_id}
          id={"#{@id_prefix}reviewer-#{reviewer.github_id}"}
          class="review-reviewer"
        >
          <.ds_identity
            :if={reviewer.identity}
            identity={reviewer.identity}
            size="xs"
            name={false}
          />
          <span :if={!reviewer.identity} translate="no">
            @{reviewer.login}
          </span>
          <span :if={reviewer.status == "invited"} class="review-reviewer-invited">Invited</span>
          <button
            :if={@can_manage}
            type="button"
            class="review-reviewer-remove"
            phx-click="remove_reviewer"
            phx-value-login={reviewer.login}
            aria-label={"Remove @#{reviewer.login}"}
            title={"Remove @#{reviewer.login}"}
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </li>
      </ul>
      <.form
        :if={@can_manage}
        for={@form}
        id={@id_prefix <> "add-reviewer-form"}
        class="review-reviewers-add"
        phx-submit="add_reviewer"
      >
        <.input
          field={@form[:login]}
          id={@id_prefix <> "add-reviewer-login"}
          type="text"
          placeholder="GitHub login"
          aria-label="GitHub login"
          autocomplete="off"
          spellcheck="false"
          required
        />
        <.ds_button type="submit" size="sm" icon="hero-user-plus">Add</.ds_button>
      </.form>
    </section>
    """
  end
end
