defmodule ReviewsWeb.DeviceController do
  @moduledoc """
  The CLI sign-in page (RFC 8628 §3.3): `reviews login` shows a code and
  this URL; the person signs in with GitHub, enters the code, checks it
  matches their terminal while a countdown shows when it expires, chooses which of their identities the CLI acts as
  (their human identity, preselected, or one of their agents), and allows or
  denies it.

    * `GET /device` - the code form, or, with `?user_code=`, the confirmation
      for that code. A link never approves anything by itself.
    * `POST /device` - looks up an entered code.
    * `POST /device/decide` - allow or deny (`Reviews.OAuth.approve_device/3`).

  Each wrong or expired code counts against the person
  (`Reviews.OAuth.DeviceAttempts`); past the limit, the page refuses codes
  for a while.
  """
  use ReviewsWeb, :controller

  alias Gatekeep.DeviceAuthorization
  alias Reviews.Accounts
  alias Reviews.OAuth
  alias Reviews.OAuth.DeviceAttempts

  def show(conn, params) do
    case {conn.assigns.current_user, params["user_code"]} do
      {nil, _} -> render_sign_in(conn)
      {_user, code} when is_binary(code) and code != "" -> check(conn, code)
      _ -> render_entry(conn, nil)
    end
  end

  def lookup(conn, params) do
    case conn.assigns.current_user do
      nil -> render_sign_in(conn)
      _user -> check(conn, entered_code(params["user_code"]))
    end
  end

  def decide(conn, %{"user_code" => code, "decision" => decision} = params)
      when is_binary(code) do
    user = conn.assigns.current_user

    # Guessing here would sign someone else's CLI in as the guesser, so a
    # decision counts against the same limit as looking a code up.
    result =
      cond do
        is_nil(user) -> :signed_out
        not DeviceAttempts.allowed?(user.id) -> {:error, :too_many_attempts}
        decision == "approve" -> OAuth.approve_device(user, code, params["identity_id"])
        true -> with :ok <- OAuth.deny_device(code), do: :denied
      end

    case result do
      :signed_out ->
        render_sign_in(conn)

      :ok ->
        render_done(conn, :approved)

      :denied ->
        render_done(conn, :denied)

      {:error, :too_many_attempts} ->
        render_entry(conn, :too_many_attempts)

      # The code was fine; only the choice was not one of theirs.
      {:error, :invalid_identity} ->
        conn
        |> put_flash(:error, "Choose one of your identities.")
        |> check(code)

      {:error, reason} ->
        DeviceAttempts.record_failure(user.id)
        render_entry(conn, reason)
    end
  end

  def decide(conn, _params), do: render_entry(conn, :invalid_user_code)

  # The form has one box per letter; joined, gatekeep drops anything that
  # isn't a letter, as it does for codes typed in one piece.
  defp entered_code(boxes) when is_list(boxes), do: Enum.map_join(boxes, &to_string/1)
  defp entered_code(code), do: to_string(code)

  defp check(conn, code) do
    user = conn.assigns.current_user

    if DeviceAttempts.allowed?(user.id) do
      case OAuth.lookup_device(code) do
        {:ok, request} ->
          {:ok, _human} = Accounts.ensure_human_identity(user)

          render(conn, :confirm,
            request: request,
            seconds_left: max(DateTime.diff(request.expires_at, DateTime.utc_now()), 0),
            # Human first, so it is the default, then agents by name.
            identities: Accounts.list_identities_for(user),
            page_title: "Sign in to the Reviews CLI"
          )

        {:error, reason} ->
          DeviceAttempts.record_failure(user.id)
          render_entry(conn, reason)
      end
    else
      render_entry(conn, :too_many_attempts)
    end
  end

  defp render_entry(conn, error) do
    conn
    |> put_status(if(error, do: :bad_request, else: :ok))
    |> render(:entry,
      error: error,
      alphabet: DeviceAuthorization.user_code_alphabet(),
      ttl_minutes: div(OAuth.config().device_code_ttl, 60),
      page_title: "Sign in to the Reviews CLI"
    )
  end

  defp render_sign_in(conn) do
    render(conn, :sign_in,
      return_to: current_path(conn),
      page_title: "Sign in to the Reviews CLI"
    )
  end

  defp render_done(conn, outcome),
    do: render(conn, :done, outcome: outcome, page_title: "Reviews CLI")
end
