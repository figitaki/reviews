defmodule ReviewsWeb.ChunkedBodyAdapter do
  @moduledoc false
  # Exercise actual reads independently of Plug.Test's pre-buffered request adapter.
  def read_req_body({chunks, observer}, _opts) do
    send(observer, :body_read)

    case chunks do
      [last] -> {:ok, last, {[], observer}}
      [head | tail] -> {:more, head, {tail, observer}}
      [] -> {:ok, "", {[], observer}}
    end
  end
end
