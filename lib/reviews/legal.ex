defmodule Reviews.Legal do
  @moduledoc """
  The deployment's Privacy Policy and Terms of Service, from
  `config :reviews, :legal` (set from `LEGAL_*` environment variables in
  `config/runtime.exs`; see `docs/LEGAL_PAGES.md`).

  Each document is one of:

    * `{:url, url}`: the operator's own policy at `url`. `/privacy` or
      `/terms` redirects there.
    * `{:template, fields}`: the built-in template at `/privacy` or `/terms`,
      filled in from config. Every field the template needs must be set.
    * `nil`: no document. Its page is a 404, and nothing links it.

  A template with some but not all of its fields set is a configuration
  error; `validate!/0` raises at boot so a half-filled policy never ships.
  """

  @shared [:operator_name, :contact_email, :updated]

  @fields %{
    privacy: @shared ++ [:hosting_region, :log_retention, :backup_retention],
    terms: @shared ++ [:governing_law, :venue, :liability_cap]
  }

  @own %{
    privacy: @fields.privacy -- @shared,
    terms: @fields.terms -- @shared
  }

  @env %{
    privacy_url: "LEGAL_PRIVACY_URL",
    terms_url: "LEGAL_TERMS_URL",
    operator_name: "LEGAL_OPERATOR_NAME",
    contact_email: "LEGAL_CONTACT_EMAIL",
    updated: "LEGAL_UPDATED",
    hosting_region: "LEGAL_HOSTING_REGION",
    log_retention: "LEGAL_LOG_RETENTION",
    backup_retention: "LEGAL_BACKUP_RETENTION",
    governing_law: "LEGAL_GOVERNING_LAW",
    venue: "LEGAL_VENUE",
    liability_cap: "LEGAL_LIABILITY_CAP"
  }

  @type kind :: :privacy | :terms
  @type document :: {:url, String.t()} | {:template, map()} | nil

  @doc "The config key for each `LEGAL_*` environment variable."
  def env_vars, do: @env

  @doc "The document configured for `kind`, from application config."
  @spec document(kind()) :: document()
  def document(kind) do
    case document(kind, config()) do
      {:error, _missing} -> nil
      document -> document
    end
  end

  @doc """
  The document `config` gives for `kind`, or `{:error, missing}` naming the
  environment variables a partly filled template still needs.
  """
  @spec document(kind(), keyword() | map()) :: document() | {:error, [String.t()]}
  def document(kind, config) when kind in [:privacy, :terms] do
    config = Map.new(config, fn {key, value} -> {key, present(value)} end)

    cond do
      url = config[:"#{kind}_url"] ->
        {:url, url}

      Enum.all?(@own[kind], &is_nil(config[&1])) ->
        nil

      true ->
        case Enum.filter(@fields[kind], &is_nil(config[&1])) do
          [] -> {:template, Map.take(config, @fields[kind])}
          missing -> {:error, Enum.map(missing, &@env[&1])}
        end
    end
  end

  @doc "Where to link `kind`: its URL, its page, or nil when there is none."
  @spec href(kind()) :: String.t() | nil
  def href(kind) do
    case document(kind) do
      {:url, url} -> url
      {:template, _} -> "/#{kind}"
      nil -> nil
    end
  end

  @doc "Raises when a document's template is only partly configured."
  def validate! do
    for kind <- [:privacy, :terms] do
      case document(kind, config()) do
        {:error, missing} ->
          raise ArgumentError,
                "the built-in #{kind} template needs #{Enum.join(missing, ", ")}. " <>
                  "Set them, set LEGAL_#{String.upcase(to_string(kind))}_URL instead, " <>
                  "or unset the #{kind} settings. See docs/LEGAL_PAGES.md."

        _ ->
          :ok
      end
    end

    :ok
  end

  defp config, do: Application.get_env(:reviews, :legal, [])

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_), do: nil
end
