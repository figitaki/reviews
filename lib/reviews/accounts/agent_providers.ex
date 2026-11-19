defmodule Reviews.Accounts.AgentProviders do
  @moduledoc """
  Agent platforms the Settings page offers when someone creates an agent
  identity. Each has its name, publisher and logo, a 96px PNG under
  `priv/static`; an identity made for one shows that logo as its avatar.
  Claude, ChatGPT and Amp share their logos with the MCP connectors
  (`config :reviews, Reviews.MCPAuth`). A provider not listed here is kept as
  typed and has no logo.

  The logos are their owners' trademarks, shown only to say which platform
  an agent runs on.
  """

  @providers [
    %{name: "Claude", publisher: "Anthropic", logo: "/images/connectors/claude.png"},
    %{name: "Codex", publisher: "OpenAI", logo: "/images/connectors/chatgpt.png"},
    %{name: "ChatGPT", publisher: "OpenAI", logo: "/images/connectors/chatgpt.png"},
    %{name: "Amp", publisher: "Amp", logo: "/images/connectors/amp.png"},
    %{name: "Cursor", publisher: "Anysphere", logo: "/images/agents/cursor.png"},
    %{name: "Gemini", publisher: "Google", logo: "/images/agents/gemini.png"},
    %{name: "GitHub Copilot", publisher: "GitHub", logo: "/images/agents/copilot.png"},
    %{name: "Grok", publisher: "xAI", logo: "/images/agents/grok.png"}
  ]

  def all, do: @providers

  @doc "The listed provider with this name, ignoring case and surrounding spaces."
  def get(name) when is_binary(name) do
    name = name |> String.trim() |> String.downcase()
    Enum.find(@providers, &(String.downcase(&1.name) == name))
  end

  def get(_name), do: nil
end
