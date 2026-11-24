defmodule Reviews.RuntimeConfigTest do
  # Reads config/runtime.exs as prod would, with the environment it is given.
  # Changes the process environment, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  @base %{
    "DATABASE_URL" => "ecto://u:p@localhost/reviews",
    "SECRET_KEY_BASE" => String.duplicate("k", 64),
    "PHX_HOST" => "reviews.example.com"
  }

  @vars ~w(DATABASE_URL SECRET_KEY_BASE PHX_HOST FLY_APP_NAME WEBSOCKET_EXTRA_ORIGINS
           AUTH_RELAY_PREVIEW_HOST)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp runtime_config(env) do
    Enum.each(@vars, &System.delete_env/1)
    System.put_env(Map.merge(@base, env))
    Config.Reader.read!("config/runtime.exs", env: :prod)
  end

  defp origins(env), do: runtime_config(env)[:reviews][ReviewsWeb.Endpoint][:check_origin]
  defp preview_host(env), do: runtime_config(env)[:reviews][:auth_relay][:preview_host]

  test "WebSocket origins: only PHX_HOST by default, plus the legacy host on Fly" do
    assert origins(%{}) == ["https://reviews.example.com"]

    assert origins(%{"FLY_APP_NAME" => "reviews-dev"}) ==
             ["https://reviews.example.com", "https://reviews-dev.fly.dev"]
  end

  test "WEBSOCKET_EXTRA_ORIGINS replaces the default, on Fly or not" do
    list = " https://a.example.com, ,https://b.example.com "

    for env <- [%{}, %{"FLY_APP_NAME" => "reviews-dev"}] do
      assert origins(Map.put(env, "WEBSOCKET_EXTRA_ORIGINS", list)) ==
               ["https://reviews.example.com", "https://a.example.com", "https://b.example.com"]

      assert origins(Map.put(env, "WEBSOCKET_EXTRA_ORIGINS", "")) ==
               ["https://reviews.example.com"]
    end
  end

  test "AUTH_RELAY_PREVIEW_HOST defaults to Fly previews and rejects a bad template" do
    assert preview_host(%{}) == "reviews-pr-*.fly.dev"
    assert preview_host(%{"AUTH_RELAY_PREVIEW_HOST" => "pr-*.example.com"}) == "pr-*.example.com"

    for bad <- ["pr.example.com", "pr-*-*.example.com", "*.example.com/x", "PR-*.example.com"] do
      assert_raise RuntimeError, ~r/AUTH_RELAY_PREVIEW_HOST/, fn ->
        runtime_config(%{"AUTH_RELAY_PREVIEW_HOST" => bad})
      end
    end
  end
end
