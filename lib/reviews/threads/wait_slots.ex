defmodule Reviews.Threads.WaitSlots do
  @moduledoc """
  Counts held comment waits (`GET /api/v1/comments/wait`) per identity and on
  this node, so one account cannot hold an unbounded number of connections and
  PubSub subscriptions. A waiting process takes a slot with `acquire/3` and
  gives it back with `release/2`; the registry also drops it if the process
  exits.
  """

  @registry Reviews.Threads.WaitRegistry
  @limits %{per_identity: 5, total: 500}

  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc """
  Takes a slot for the calling process, or returns `{:error, :rate_limited}`
  when the identity or the node already holds its limit.
  """
  def acquire(identity_id, limits \\ @limits, registry \\ @registry) do
    {:ok, _owner} = Registry.register(registry, identity_id, nil)

    # Register first, then count: two racing callers may both be refused, but
    # neither can push the count past a limit.
    if length(Registry.lookup(registry, identity_id)) > limits.per_identity or
         Registry.count(registry) > limits.total do
      release(identity_id, registry)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  # Bandit reuses the request process on a keep-alive connection, so the slot
  # must be released explicitly, not only on exit.
  def release(identity_id, registry \\ @registry), do: Registry.unregister(registry, identity_id)
end
