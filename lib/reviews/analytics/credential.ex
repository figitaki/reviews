defmodule Reviews.Analytics.Credential do
  @moduledoc "Dedicated, expiring aggregate-export credentials; never user API tokens."

  def authenticate(token) when is_binary(token) and byte_size(token) == 47 do
    with true <- Regex.match?(~r/\Arva_[A-Za-z0-9_-]{43}\z/, token),
         {:ok, digest} <- configured_digest(),
         true <- Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), digest) do
      {:ok, digest}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate(_), do: {:error, :unauthorized}

  def current?(digest) do
    case configured_digest() do
      {:ok, current} -> Plug.Crypto.secure_compare(digest, current)
      _ -> false
    end
  end

  def configured_digest do
    config = Application.get_env(:reviews, :analytics_export, [])

    with hash when is_binary(hash) <- config[:token_sha256],
         {:ok, digest} when byte_size(digest) == 32 <- Base.decode16(hash, case: :mixed),
         expiry when is_binary(expiry) <- config[:expires_at],
         {:ok, expires_at, 0} <- DateTime.from_iso8601(expiry),
         seconds when seconds > 0 and seconds <= 90 * 86_400 <-
           DateTime.diff(expires_at, DateTime.utc_now()) do
      {:ok, digest}
    else
      _ -> {:error, :disabled}
    end
  end
end
