defmodule Reviews.Poppy do
  @moduledoc """
  Reviews as a Personal Agent Protocol (Poppy 1.0) Company.

  A Personal Agent proves who it is with its `client_id` and signed Session
  JWTs (spec 4.1, 5.2). That never grants account access (spec 5.3). To act
  as a Reviews identity, the identity's owner approves the Personal Agent
  through Direct Sign-In (spec 4.2) on the Reviews OAuth issuer
  (`Reviews.OAuth`): the owner signs in with GitHub, picks one of their agent
  identities, and approves scopes. The approval is a grant
  (`Reviews.OAuth.Grant`) for this resource, and every token issued under it
  acts as that identity. No new account or actor namespace is created.

  This module is the Poppy API's `Reviews.OAuth.Resource`: its identifier is
  the domain (spec 3.2), it takes only clients with keys, because the API
  needs Session JWTs, a sign-in must name its scope, and its refresh tokens
  don't rotate (spec 4.4). Tokens are bound to the key of a token request's
  DPoP proof (spec 4.5); the issuer's `dpop_signing_algs` are ES256, the
  algorithm of Session JWTs.

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
  def options do
    [
      id: resource(),
      scopes: Enum.map(scope_names(), &{&1, @scopes[&1]}),
      default_scopes: [],
      # The Poppy API needs Session JWTs, which only a client with keys signs.
      client_auth_methods: ["private_key_jwt"],
      rotate_refresh_tokens: false
    ]
  end

  def provider, do: @provider
  def protocol_version, do: @protocol_version
  def scopes, do: @scopes
  def scope_names, do: Map.keys(@scopes)
  def scope_hints, do: @scope_hints

  @doc "DPoP proof algorithms (RFC 9449) the issuer and the Poppy API accept."
  def dpop_signing_algs, do: OAuth.config().dpop_signing_algs

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

  @doc "The resource identifier (RFC 8707) of the Poppy API: the domain."
  def resource, do: "https://" <> organization_domain()

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
