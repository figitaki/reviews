defmodule Reviews.OAuth.RegisteredClient do
  @moduledoc """
  A public OAuth client registered through dynamic client registration
  (RFC 7591). Its name is what it calls itself and is never shown as
  verified.
  """
  use Ecto.Schema

  schema "oauth_clients" do
    field :client_id, :string
    field :client_name, :string
    field :redirect_uris, {:array, :string}

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
