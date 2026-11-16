# Example Poppy Personal Agent

A Personal Agent in one dependency-free Node file (Node 20+). Use it to try Reviews as a Poppy 1.0
Company. It isn't a production agent: its keys and tokens are stored in local files.

```sh
# 1. Create keys and metadata. Host agent.json and jwks.json at --base-url over HTTPS, without redirects.
node poppy-agent.mjs keygen --base-url https://you.example/agent --name "My agent"

# 2. Sign in. Open the printed link, sign in to Reviews with GitHub, pick an agent identity, and click Allow.
#    Tokens are DPoP-bound when the Company supports it; add --no-dpop for Bearer tokens.
node poppy-agent.mjs sign-in https://reviews.example

# 3. Read a review signed out, then comment as the approved agent identity.
node poppy-agent.mjs get https://reviews.example /api/poppy/v1/reviews/<slug>
node poppy-agent.mjs comment https://reviews.example <slug> --file lib/a.ex --line 12 --body "Looks good"

# 4. Sign out (revokes the refresh token).
node poppy-agent.mjs sign-out https://reviews.example
```

When the Company's issuer lists ES256 in `dpop_signing_alg_values_supported`, sign-in creates a
DPoP key (RFC 9449) for that Company's User ID and sends a proof with each token request, so the
Company can bind the tokens to the key. The key is saved with the refresh token and used for every
refresh. Requests with a `DPoP` token carry a proof as well as the Session JWT, each signed with its
own key. Pass `--no-dpop` to `sign-in` to get Bearer tokens instead. The example doesn't handle
DPoP nonces (`use_dpop_nonce`), because Reviews doesn't issue them.

Sign-in uses a loopback redirect (`http://127.0.0.1:<port>/callback`), so the browser must run on
the same machine as the agent. State is kept in `.poppy-agent/` with mode 0600. Keep those files
away from a model's context (spec 10.2).

Pass `--allow-private-addresses` only to test a Company on a local or private network.
