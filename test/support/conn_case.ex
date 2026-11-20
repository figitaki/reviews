defmodule ReviewsWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ReviewsWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ReviewsWeb.Endpoint

      use ReviewsWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ReviewsWeb.ConnCase
    end
  end

  setup tags do
    Reviews.DataCase.setup_sandbox(tags)
    # Each test represents a separate client; budgets remain enabled in tests.
    n = System.unique_integer([:positive, :monotonic])

    ip =
      {10, Bitwise.band(Bitwise.bsr(n, 16), 255), Bitwise.band(Bitwise.bsr(n, 8), 255),
       Bitwise.band(n, 255)}

    {:ok, conn: %{Phoenix.ConnTest.build_conn() | remote_ip: ip}}
  end
end
