defmodule ReviewsWeb.SettingsLive do
  @moduledoc """
  Per-user settings page. v1 has one feature: mint an API token for the CLI.

  Tokens are opaque — we generate one, show it ONCE in the flash/banner, and
  only persist its SHA-256 hash. Subsequent visits show token *metadata* (name,
  last_used_at) but never the raw value.
  """
  use ReviewsWeb, :live_view

  alias Reviews.Accounts

  @impl true
  def mount(_params, session, socket) do
    user_id = session["current_user_id"]

    case user_id && safe_load_user(user_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "You must sign in to manage tokens.")
         |> push_navigate(to: ~p"/")}

      user ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:tokens, Accounts.list_tokens_for(user))
         |> assign(:new_token, nil)}
    end
  end

  @impl true
  def handle_event("mint_token", %{"name" => name}, socket) do
    user = socket.assigns.current_user

    case Accounts.mint_token(user, %{"name" => name}) do
      {:ok, _token, raw} ->
        {:noreply,
         socket
         |> assign(:new_token, raw)
         |> assign(:tokens, Accounts.list_tokens_for(user))
         |> put_flash(:info, "Token generated. Copy it now — it will not be shown again.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not generate token.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <h1 class="text-2xl font-semibold">Settings</h1>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">API tokens</h2>
          <p class="text-sm text-base-content/70">
            Tokens authenticate the <code>reviews</code> CLI. Generated tokens are
            shown once and stored only as a hash.
          </p>

          <form id="mint-token-form" phx-submit="mint_token" class="flex gap-2 items-end">
            <label class="flex flex-col text-sm">
              <span>Token name</span>
              <input
                type="text"
                name="name"
                placeholder="laptop"
                class="border rounded px-2 py-1"
              />
            </label>
            <button type="submit" class="px-3 py-1 border rounded bg-base-200">
              Generate token
            </button>
          </form>

          <div
            :if={@new_token}
            id="new-token-banner"
            class="p-3 border rounded bg-base-200 font-mono break-all"
          >
            {@new_token}
          </div>

          <ul id="tokens-list" class="text-sm space-y-1">
            <li :for={t <- @tokens} id={"token-#{t.id}"}>
              <span>{t.name || "(unnamed)"}</span>
              <span class="text-base-content/60">
                — created {Calendar.strftime(t.inserted_at, "%Y-%m-%d")}
              </span>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp safe_load_user(id) do
    try do
      Accounts.get_user!(id)
    rescue
      Ecto.NoResultsError -> nil
    end
  end
end
