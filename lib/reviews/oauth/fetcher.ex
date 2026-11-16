defmodule Reviews.OAuth.Fetcher do
  @moduledoc """
  Fetches a client's metadata document and key set.

  Every URL comes from the other party, so the fetch is limited: HTTPS only, no redirects, no cookies or
  credentials, a 100 KB body limit, short timeouts, and no loopback, private,
  or link-local addresses unless the host is listed in `:allow_private_hosts`
  on purpose (development and tests). The connection goes to the address that
  was checked, not to a second DNS answer.

  Tests replace this module with `config :reviews, Reviews.OAuth, fetcher: ...`.
  """

  @callback get(String.t()) :: {:ok, %{status: integer(), body: binary()}} | {:error, term()}

  @max_body 100_000
  @timeout 5_000

  def get(url) do
    impl = Reviews.OAuth.config(:fetcher, __MODULE__)
    if impl == __MODULE__, do: fetch(url), else: impl.get(url)
  end

  defp fetch(url) do
    with %URI{scheme: "https", host: host, port: port, userinfo: nil} = uri
         when is_binary(host) and host != "" <- URI.parse(url),
         {:ok, address} <- resolve(host) do
      request(uri, address, port)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_url}
    end
  end

  defp resolve(host) do
    charlist = String.to_charlist(host)

    addresses =
      case :inet.parse_address(charlist) do
        {:ok, ip} ->
          [ip]

        {:error, _} ->
          Enum.flat_map([:inet, :inet6], fn family ->
            case :inet.getaddrs(charlist, family) do
              {:ok, ips} -> ips
              _ -> []
            end
          end)
      end

    allowed_private = host in Reviews.OAuth.config(:allow_private_hosts, [])

    cond do
      addresses == [] -> {:error, :unresolved}
      allowed_private -> {:ok, hd(addresses)}
      Enum.any?(addresses, &private_address?/1) -> {:error, :private_address}
      true -> {:ok, hd(addresses)}
    end
  end

  defp request(%URI{} = uri, address, port) do
    host = uri.host
    ip = address |> :inet.ntoa() |> to_string()
    ip_host = if tuple_size(address) == 8, do: "[#{ip}]", else: ip
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    target = ~c"https://#{ip_host}:#{port}#{path}"
    host_header = if port == 443, do: host, else: "#{host}:#{port}"

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      depth: 4
    ]

    http_opts = [timeout: @timeout, connect_timeout: 3_000, autoredirect: false, ssl: ssl]
    headers = [{~c"host", String.to_charlist(host_header)}, {~c"accept", ~c"application/json"}]

    case :httpc.request(:get, {target, headers}, http_opts, sync: false, stream: :self) do
      {:ok, ref} -> receive_body(ref, [], 0)
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_body(ref, acc, size) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        receive_body(ref, acc, size)

      {:http, {^ref, :stream, chunk}} ->
        size = size + byte_size(chunk)

        if size > @max_body do
          :httpc.cancel_request(ref)
          {:error, :too_large}
        else
          receive_body(ref, [acc, chunk], size)
        end

      {:http, {^ref, :stream_end, _headers}} ->
        {:ok, %{status: 200, body: IO.iodata_to_binary(acc)}}

      {:http, {^ref, {{_version, status, _reason}, _headers, body}}} ->
        {:ok, %{status: status, body: if(byte_size(body) > @max_body, do: "", else: body)}}

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason}
    after
      @timeout + 1_000 ->
        :httpc.cancel_request(ref)
        {:error, :timeout}
    end
  end

  @doc false
  def private_address?({a, b, _, _}) do
    a in [0, 10, 127] or (a == 169 and b == 254) or (a == 172 and b in 16..31) or
      (a == 192 and b == 168) or (a == 100 and b in 64..127) or a >= 224
  end

  def private_address?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: private_address?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  def private_address?({0, 0, 0, 0, 0, 0, 0, a}) when a in [0, 1], do: true
  def private_address?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  def private_address?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  def private_address?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: true
  def private_address?(_), do: false
end
