defmodule Reviews.Poppy do
  @moduledoc """
  Reviews as a Personal Agent Protocol (Poppy 1.0) Company.

  A Personal Agent proves who it is with its `client_id` and signed Session
  JWTs (spec 4.1, 5.2). That never grants account access (spec 5.3). To act
  as a Reviews identity, the identity's owner approves the Personal Agent
  through Direct Sign-In (spec 4.2) on the Reviews OAuth issuer
  (`Reviews.OAuth`): the owner signs in with GitHub, picks one of their agent
  identities, and approves scopes. The approval is an
  `Reviews.Accounts.IdentityLink` with provider `"poppy"`, and every token
  issued under it acts as that identity. No new account or actor namespace is
  created.

  This module is the Poppy API's `Reviews.OAuth.Resource`: its identifier is
  the domain (spec 3.2), it takes only clients with keys, because the API
  needs Session JWTs, and its refresh tokens don't rotate (spec 4.4).

  See `docs/POPPY.md` for the contract and `.plans/poppy-reference-merchant.md`
  for what was verified against the specification.
  """
  @behaviour Reviews.OAuth.Resource

  import Ecto.Query, warn: false

  alias Reviews.OAuth
  alias Reviews.Poppy.Session
  alias Reviews.Repo

  @provider "poppy"
  @protocol_version "1.0"

  @scopes %{
    "comments:write" =>
      "Post review comments and replies as the Reviews agent you choose. Needed to comment on a review. Reading a public review needs no sign-in."
  }

  @scope_hints %{"comments:write" => %{"changes" => "irreversible", "personal_data" => false}}

  @impl true
  def provider, do: @provider
  def protocol_version, do: @protocol_version
  @impl true
  def scopes, do: @scopes
  @impl true
  def scope_names, do: Map.keys(@scopes)
  def scope_hints, do: @scope_hints

  @doc "Reads `config :reviews, Reviews.Poppy, key: value`."
  def config(key, default \\ nil) do
    :reviews |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  @doc """
  The Company's identifier, which is the OAuth issuer and the audience of
  Session JWTs (spec 3.2).
  """
  def issuer, do: OAuth.issuer()

  @doc "`organization.domain`: the issuer's host, with its port when it isn't 443."
  def organization_domain do
    %URI{host: host, port: port} = URI.parse(issuer())
    if port in [nil, 443], do: host, else: "#{host}:#{port}"
  end

  @impl true
  def resource, do: "https://" <> organization_domain()

  @impl true
  def enabled?, do: true

  # The Poppy API needs Session JWTs, which only a client with keys signs.
  @impl true
  def client_auth_methods, do: ["private_key_jwt"]

  @impl true
  def rotate_refresh_tokens?, do: false

  @doc "Parses a space-separated scope string. Missing or unknown scopes are `:error`."
  @impl true
  def parse_scopes(scope) when is_binary(scope) do
    scopes = scope |> String.split(" ", trim: true) |> Enum.uniq()

    if scopes != [] and Enum.all?(scopes, &Map.has_key?(@scopes, &1)),
      do: {:ok, scopes},
      else: :error
  end

  def parse_scopes(_), do: :error

  @impl true
  def consent_text(client_label) do
    %{
      eyebrow: "Connect an agent",
      title: "Let this agent act for you?",
      sign_in:
        "#{client_label} wants to act as one of your Reviews agents. Sign in with GitHub to choose which one.",
      description:
        "#{client_label} wants to post as one of your Reviews agents. Continue only if you just asked it to connect.",
      note:
        "Comments it posts show as your agent, with a \"Verified agent\" label naming this domain. You can disconnect it at any time in Settings."
    }
  end

  @doc """
  Looks up a Poppy access token. See `Reviews.OAuth.authenticate_access_token/2`.
  """
  def authenticate_access_token(token), do: OAuth.authenticate_access_token(token, @provider)

  ## Sessions (spec 5.3, 5.4)

  @doc """
  Starts or continues the Session named by verified claims. A Session that
  used one Reviews identity can't switch to another (spec 5.4): that returns
  `{:error, :session_ended}`, and the Personal Agent starts a new Session.
  """
  def touch_session(%{client: client, sid: sid, sub: sub, agent_id: agent_id}, identity_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      Session,
      [
        %{
          client_id: client.client_id,
          sid: sid,
          sub: sub,
          agent_id: agent_id,
          last_seen_at: now,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:client_id, :sid, :sub]
    )

    # Claim the Session for this identity unless it already used another one.
    if identity_id do
      Repo.update_all(
        from(s in Session,
          where:
            s.client_id == ^client.client_id and s.sid == ^sid and s.sub == ^sub and
              is_nil(s.identity_id)
        ),
        set: [identity_id: identity_id]
      )
    end

    session = Repo.get_by!(Session, client_id: client.client_id, sid: sid, sub: sub)

    cond do
      session.ended_at != nil -> {:error, :session_ended}
      session.agent_id != agent_id -> {:error, :agent_id_changed}
      identity_id && session.identity_id != identity_id -> {:error, :session_ended}
      true -> {:ok, session}
    end
  end
end
