defmodule Reviews.AuthRelay do
  @moduledoc """
  Sign-in relay for preview apps (`reviews-pr-<N>.fly.dev`).

  A GitHub OAuth app has one callback URL, and GitHub only sends users back to
  that host, so a preview cannot finish GitHub sign-in on its own host. One
  stable host, the relay, does the GitHub sign-in instead. It sends the user
  back to the preview with a code from `issue_code/4`, and the preview turns
  the code into a session with `redeem_code/3`.

  A code is encrypted and authenticated with the shared `AUTH_RELAY_SECRET`.
  It names the preview host and the sign-in state that the preview stored in
  its session, expires after 60 seconds, and can be redeemed once.

  Config (`config :reviews, :auth_relay`, set in `config/runtime.exs`):

    * relay: `:secret` and no `:url`. It signs in with the app's own GitHub
      OAuth app (`GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET`).
    * preview: `:secret` and `:url`, the relay's origin
  """
  import Ecto.Query

  alias Reviews.Repo

  @salt "reviews auth relay code v1"
  @max_age 60
  @host_pattern ~r/\Areviews-pr-[0-9]+\.fly\.dev\z/
  @state_pattern ~r/\A[A-Za-z0-9_-]{22,128}\z/

  @doc "Returns true when this app can act as the relay."
  def relay? do
    github = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, [])

    present?(config()[:secret]) and not present?(config()[:url]) and
      present?(github[:client_id]) and present?(github[:client_secret])
  end

  @doc "Returns true when this app signs in through a relay."
  def client?, do: present?(config()[:secret]) and present?(config()[:url])

  @doc "The relay's origin, such as `https://reviews.figitaki.dev`."
  def relay_url, do: config()[:url] |> String.trim_trailing("/")

  @doc """
  Returns true for the only hosts the relay sends users back to, and the only
  hosts that accept relay codes: `reviews-pr-<digits>.fly.dev`, with no port,
  path or other characters.
  """
  def allowed_host?(host) when is_binary(host), do: Regex.match?(@host_pattern, host)
  def allowed_host?(_), do: false

  @doc "Returns true when `state` has the shape `new_state/0` produces."
  def valid_state?(state) when is_binary(state), do: Regex.match?(@state_pattern, state)
  def valid_state?(_), do: false

  @doc "A random sign-in state for the preview to keep in its session."
  def new_state, do: random_token()

  @doc """
  Issues a code that signs `user` in on `host`, for the sign-in that stored
  `state`. `opts` go to `Plug.Crypto.encrypt/4`, such as `:signed_at`.
  """
  def issue_code(host, state, user, opts \\ []) do
    payload = %{
      host: host,
      state: state,
      nonce: random_token(),
      user: Map.take(user, [:github_id, :username, :avatar_url, :email])
    }

    Plug.Crypto.encrypt(secret!(), @salt, payload, Keyword.put(opts, :max_age, @max_age))
  end

  @doc """
  Checks a code on `host` against the `state` in the preview's session and
  marks it used. Returns `{:ok, user_attrs}` for `Reviews.Accounts.upsert_from_github/1`
  or `{:error, reason}`, where reason is `:invalid`, `:expired`,
  `:wrong_host`, `:wrong_state` or `:replayed`.
  """
  def redeem_code(code, host, state) when is_binary(code) do
    with {:ok, %{host: code_host, state: code_state, nonce: nonce, user: user}} <-
           decrypt(code),
         :ok <- check(code_host == host, :wrong_host),
         :ok <-
           check(is_binary(state) and Plug.Crypto.secure_compare(code_state, state), :wrong_state),
         :ok <- consume(nonce) do
      {:ok, user}
    end
  end

  def redeem_code(_code, _host, _state), do: {:error, :invalid}

  defp decrypt(code) do
    case Plug.Crypto.decrypt(secret!(), @salt, code, max_age: @max_age) do
      {:ok, %{host: _, state: _, nonce: _, user: _} = payload} -> {:ok, payload}
      {:ok, _other} -> {:error, :invalid}
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  # Used nonces only need to outlive the codes that carry them (@max_age).
  defp consume(nonce) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    cutoff = NaiveDateTime.add(now, -10, :minute)

    Repo.delete_all(from c in "auth_relay_codes", where: c.inserted_at < ^cutoff)

    case Repo.insert_all("auth_relay_codes", [%{nonce: nonce, inserted_at: now}],
           on_conflict: :nothing
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :replayed}
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp secret!, do: config()[:secret] || raise("AUTH_RELAY_SECRET is not set")

  defp config, do: Application.get_env(:reviews, :auth_relay, [])

  defp present?(value), do: is_binary(value) and value != ""

  defp random_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
end
