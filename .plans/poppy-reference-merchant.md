# Poppy reference merchant: protocol verification and gaps (issue #154)

Checked 2026-11-16 against:

- Spec 1.0: https://personalagentprotocol.org/docs/1.0/spec, at repository
  `personal-agent-protocol/personal-agent-protocol` commit `85b41ff` (2026-11-14). Sierra announced
  1.0 on 2026-11-13, but the official changelog still calls it a draft that can break compatibility.
- A working client: the official Company kit validator (`kit/company/validate`) at the same commit.
  It acts as a test Personal Agent and signs real Session JWTs, delegations, and client assertions.
- Cross-implementation vectors: `test/support/fixtures/poppy/kit_vectors.json`, signed by the kit's
  `jose.ts` (regenerate with `generate_kit_vectors.ts`), and RFC 7515 A.3 and RFC 7638 vectors.

## Verified

| Area | Spec | Result |
| --- | --- | --- |
| Discovery: `poppy.json`, RFC 9728 resource metadata, RFC 8414 issuer metadata with `protected_resources` | 3, 3.1, 3.2 | Validator `discovery.*`, `metadata.*`: pass |
| Agent identity: CIMD `client_id`, `jwks_uri` on the same host, no redirects | 4.1 | Implemented. Validator fetches pass. |
| Client assertions: `private_key_jwt`, `aud` = issuer as a string, ES256 and PS384, at most 5 minutes, `jti` reuse | 4.1, guides | Validator `assertion.*` (8 checks): pass |
| Session JWT and delegations: typ, alg, kid thumbprint, `poppy_dlg`, 24 h limit, ES256/PS384 delegation, aud, htm/htu, iat, ath | 5.2, 5.3 | Validator `session.*` (30 checks): pass |
| Errors: 400 `invalid_session`, `session_ended`, `version_unsupported`; 401 `invalid_token` in `WWW-Authenticate` | 3.4, 5.3, 7 | Validator: pass |
| OpenAPI channel | 7 | Validator `openapi.*`: pass |
| Direct Sign-In: PKCE S256, exact redirect URI (loopback port excepted), `iss` on every redirect, consent page always shown | 4.2, 10.8 | Exercised live with `examples/poppy-agent` and covered by tests. The validator doesn't check sign-in. |

Validator result against a live dev deployment over HTTPS: Foundation **58 passed, 0 failed,
0 warnings, 7 skipped**. Every skip is a feature Reviews doesn't offer: Device Sign-In, extensions,
other versions or domains, and conversation, feedback, or browser endpoints.

## Gaps and differences

1. **No real third-party agent was tested.** I found no public Poppy Personal Agent (Meta's Muse,
   OpenClaw, or a Claude client) to point at Reviews. The tests used the official validator and an
   example agent. The acceptance criterion "a real supported agent authenticates" is still open.
2. **Poppy doesn't carry the parties #154 wants to separate.** `sub` is a pseudonymous ID per
   Company (5.1). `agent_id` is optional, chosen by the agent, and unverifiable. There is no workload
   attestation or owner-to-agent delegation chain, and a delegation names no User (5.2). Reviews
   therefore verifies:
   the Personal Agent's key control (by `client_id` domain) plus an owner approval recorded in Reviews.
   It shows workload and delegation as "not established".
3. **A Session JWT never grants account access (5.3).** Linking to a Reviews identity has to go
   through OAuth sign-in, which is why Reviews runs a small issuer instead of accepting Session
   identity alone.
4. **Delegations can't be revoked early (10.7).** Key revocation takes effect once Reviews' metadata
   cache expires, 5 minutes by default. Link revocation takes effect immediately.
5. **Draft status.** The 1.0 text can still change incompatibly. The verifier is ours, not a
   library's, so a spec change means a code change.
6. **Not implemented:** DPoP-bound tokens (optional), PAR, Device Sign-In, refresh token rotation,
   Web Bot Auth operator signatures (optional for the Company), 429 rate limits, rejecting a
   delegated key reused across User IDs (MAY), conversations, tasks, feedback, and browser join.
7. **Local testing.** Personal Agents must refuse private addresses. Testing behind a tunnel or
   portal that resolves to loopback needs `--allow-private-addresses` in the validator and
   `OAUTH_ALLOW_PRIVATE_HOSTS` in Reviews.

## Path to Turnkey or DID

`Reviews.ExternalIdentity` is the adapter boundary. A Turnkey-issued delegation or DPoP key, or a
did:web whose `authentication` key signs the challenge, becomes another adapter that resolves to an
`identity_links` row with its own `provider`. Comments then record that adapter's `attribution`.
Signed section decisions (#106) remain separate evidence. A Poppy login is not a signed decision.
