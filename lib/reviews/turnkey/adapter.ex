defmodule Reviews.Turnkey.Adapter do
  @moduledoc """
  `Reviews.ExternalIdentity` for Poppy requests from Personal Agents whose
  identity key lives in Turnkey (`Reviews.Turnkey`).

  It runs `Reviews.Poppy.Adapter` first, so every Poppy check and the
  owner-approved grant stay the same, and the request still acts as the
  identity the owner approved. Actor IDs don't change. For a Turnkey-hosted
  `client_id`, it then checks the request's delegation against Turnkey's
  `poppy-delegation/v1` profile and records the result in `attribution`:

    * `"delegation_signed_by" => "turnkey"`, with the profile, the Turnkey
      organization ID and agent slug, the identity key's thumbprint, and the
      delegation's `jti`, when it checks out;
    * `"delegation_signed_by" => nil` and `"turnkey_delegation_problem"`
      when it doesn't. The request still succeeds, because the delegation
      already verified as a Poppy delegation; only the Turnkey claim is
      withheld.

  Other agents get the Poppy adapter's result unchanged.
  """
  @behaviour Reviews.ExternalIdentity

  alias Gatekeep.{Clients, JOSE}
  alias Reviews.{OAuth, Poppy}
  alias Reviews.Turnkey

  @impl true
  def authenticate(request, opts \\ []) do
    with {:ok, result} <- Poppy.Adapter.authenticate(request, opts) do
      extra = turnkey_attribution(request, result.attribution, opts)
      {:ok, %{result | attribution: Map.merge(result.attribution, extra)}}
    end
  end

  defp turnkey_attribution(request, %{"client_id" => client_id} = attribution, opts) do
    case Turnkey.hosted_agent(client_id) do
      {:ok, _agent} ->
        with {:ok, client} <- Clients.fetch(OAuth.config(), client_id),
             {:ok, delegation} <- delegation(request.headers["poppy-session"]),
             {:ok, verified} <-
               Turnkey.verify_delegation(delegation, client, attribution["delegated_key"], opts) do
          %{
            "delegation_signed_by" => "turnkey",
            "delegation_profile" => verified.profile,
            "delegation_jti" => verified.jti,
            "turnkey_organization_id" => verified.organization_id,
            "turnkey_agent" => verified.agent,
            "turnkey_identity_key" => verified.identity_key
          }
        else
          {:error, reason} ->
            %{"delegation_signed_by" => nil, "turnkey_delegation_problem" => to_string(reason)}
        end

      :error ->
        %{}
    end
  end

  # The Poppy adapter already verified this Session JWT and its delegation.
  defp delegation(session_jwt) do
    case JOSE.decode(session_jwt) do
      {:ok, %{header: %{"poppy_dlg" => dlg}}} when is_binary(dlg) -> {:ok, dlg}
      _ -> {:error, :malformed}
    end
  end
end
