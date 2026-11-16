defmodule Reviews.OAuth.TokensTest do
  use Reviews.DataCase, async: false

  alias Reviews.OAuth.{Clients, JOSE, Tokens}
  alias Reviews.OAuthTestClient, as: Client

  describe "JOSE" do
    test "verifies the RFC 7515 A.3 ES256 example and rejects a changed payload" do
      jwk = %{
        "kty" => "EC",
        "crv" => "P-256",
        "x" => "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
        "y" => "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"
      }

      jws =
        "eyJhbGciOiJFUzI1NiJ9." <>
          "eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ." <>
          "DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q"

      assert {:ok, decoded} = JOSE.decode(jws)
      assert JOSE.verify(decoded, jwk, ["ES256"])
      refute JOSE.verify(decoded, jwk, ["PS384"])
      refute JOSE.verify(%{decoded | signing_input: decoded.signing_input <> "x"}, jwk, ["ES256"])
    end

    test "computes the RFC 7638 example thumbprint" do
      jwk = %{
        "kty" => "RSA",
        "e" => "AQAB",
        "n" =>
          "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw"
      }

      assert JOSE.thumbprint(jwk) == {:ok, "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"}
    end
  end

  describe "verify_client_assertion/2" do
    setup do
      %{client: Client.new()}
    end

    test "accepts ES256 and PS384 assertions addressed to the issuer", %{client: client} do
      assert {:ok, %{client_id: id}} = Tokens.verify_client_assertion(Client.client_auth(client))
      assert id == client.client_id
      assert {:ok, _} = Tokens.verify_client_assertion(Client.client_auth(client, rsa: true))
    end

    test "refuses the token endpoint, or a list, as the audience, unless the client is listed",
         %{client: client} do
      for aud <- ["https://reviews.test/oauth/token", ["https://reviews.test"]] do
        assert {:error, :wrong_audience} =
                 Tokens.verify_client_assertion(Client.client_auth(client, aud: aud))
      end

      listed = Client.new()
      previous = Application.get_env(:reviews, Reviews.OAuth)
      on_exit(fn -> Application.put_env(:reviews, Reviews.OAuth, previous) end)

      Application.put_env(
        :reviews,
        Reviews.OAuth,
        Keyword.put(previous, :token_endpoint_audience_clients, [listed.client_id])
      )

      assert {:ok, _} =
               Tokens.verify_client_assertion(
                 Client.client_auth(listed, aud: "https://reviews.test/oauth/token")
               )

      assert {:error, :wrong_audience} =
               Tokens.verify_client_assertion(
                 Client.client_auth(client, aud: "https://reviews.test/oauth/token")
               )
    end

    test "refuses expired, long-lived, and replayed assertions", %{client: client} do
      now = Client.now()

      assert {:error, :expired} =
               Tokens.verify_client_assertion(
                 Client.client_auth(client, iat: now - 600, exp: now - 300)
               )

      assert {:error, :assertion_too_long} =
               Tokens.verify_client_assertion(Client.client_auth(client, exp: now + 3600))

      params = Client.client_auth(client)
      assert {:ok, _} = Tokens.verify_client_assertion(params)
      assert {:error, :replayed} = Tokens.verify_client_assertion(params)
    end

    test "refuses an assertion signed by another client's key", %{client: client} do
      other = Client.new()

      forged =
        Client.client_auth(%{
          other
          | client_id: client.client_id,
            root: %{other.root | kid: client.root.kid}
        })

      assert {:error, :bad_signature} = Tokens.verify_client_assertion(forged)
    end
  end

  describe "Clients.fetch/1" do
    test "refuses client metadata whose client_id doesn't match its URL" do
      client = Client.new(metadata: %{"client_id" => "https://elsewhere.example/client.json"})

      assert {:error, :invalid_client_metadata} = Clients.fetch(client.client_id)
    end

    test "a key removed from jwks_uri stops verifying once the cache is refreshed" do
      client = Client.new()
      assert {:ok, _} = Tokens.verify_client_assertion(Client.client_auth(client))

      Client.publish(client, %{}, [client.rsa.public])
      Clients.forget(client.client_id)

      assert {:error, :bad_signature} = Tokens.verify_client_assertion(Client.client_auth(client))
      assert {:ok, _} = Tokens.verify_client_assertion(Client.client_auth(client, rsa: true))
    end
  end
end
