// Generates kit_vectors.json: JWTs signed by the official Poppy kit's JOSE code, so the
// Elixir verifier is tested against another implementation, not only against itself.
//
// Run from the repository root with Node 22.18 or later, passing a checkout of
// https://github.com/personal-agent-protocol/personal-agent-protocol:
//
//   node test/support/fixtures/poppy/generate_kit_vectors.ts /path/to/personal-agent-protocol
//
// The vectors hold public keys and signed JWTs only. Tests verify them at the fixed `now`.

import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const repo = resolve(process.argv[2] ?? "");
const jose = await import(pathToFileURL(join(repo, "kit/company/validate/jose.ts")).href);
const commit = execFileSync("git", ["-C", repo, "rev-parse", "HEAD"]).toString().trim();

const now = 1_800_000_000;
const issuer = "https://reviews.test";
const base = "https://kit-agent.example";
const clientId = `${base}/agent.json`;

const root = await jose.generateKey(true);
root.publicJwk.kid = "kit-es256";
const rsa = await jose.generateRsaKey();
rsa.publicJwk.kid = "kit-ps384";
const delegated = await jose.generateKey();

const delegation = await jose.signDelegation({
    root,
    delegated: delegated.publicJwk,
    iss: clientId,
    iat: now - 600,
});
const rsaDelegation = await jose.signDelegation({
    root: rsa,
    delegated: delegated.publicJwk,
    iss: clientId,
    iat: now - 600,
});

const session = (options: Record<string, unknown>) =>
    jose.signSessionJwt({
        key: delegated,
        delegation,
        iss: clientId,
        aud: issuer,
        sid: "kit_session_1",
        sub: "kit_user_1",
        method: "GET",
        url: `${issuer}/api/poppy/v1/reviews/abc?ignored=query`,
        iat: now - 5,
        ...options,
    });

const assertionClaims = (jti: string) => ({
    iss: clientId,
    sub: clientId,
    aud: issuer,
    iat: now - 5,
    exp: now + 115,
    jti,
});

const vectors = {
    source: {
        repository: "https://github.com/personal-agent-protocol/personal-agent-protocol",
        commit,
        file: "kit/company/validate/jose.ts",
    },
    now,
    issuer,
    metadata: {
        client_id: clientId,
        client_name: "Kit test agent",
        jwks_uri: `${base}/jwks.json`,
        redirect_uris: [`${base}/callback`],
        token_endpoint_auth_method: "private_key_jwt",
    },
    jwks: {
        keys: [
            { ...root.publicJwk, alg: "ES256", use: "sig" },
            { ...rsa.publicJwk, alg: "PS384", use: "sig" },
        ],
    },
    delegated_key_thumbprint: await jose.thumbprint(delegated.publicJwk),
    sessions: {
        signed_out: {
            method: "GET",
            url: `${issuer}/api/poppy/v1/reviews/abc`,
            jwt: await session({}),
        },
        ps384_delegation: {
            method: "GET",
            url: `${issuer}/api/poppy/v1/reviews/abc`,
            jwt: await session({ delegation: rsaDelegation }),
        },
        signed_in: {
            method: "POST",
            url: `${issuer}/api/poppy/v1/reviews/abc/comments`,
            access_token: "ppa_kit_access_token",
            agent_id: "kit_agent_1",
            jwt: await session({
                method: "POST",
                url: `${issuer}/api/poppy/v1/reviews/abc/comments`,
                accessToken: "ppa_kit_access_token",
                agentId: "kit_agent_1",
            }),
        },
    },
    client_assertions: {
        es256: await jose.signJwt(
            { alg: "ES256", typ: "JWT", kid: "kit-es256" },
            assertionClaims("kit_assertion_es256"),
            root.privateKey,
        ),
        ps384: await jose.signPs384(
            { alg: "PS384", typ: "JWT", kid: "kit-ps384" },
            assertionClaims("kit_assertion_ps384"),
            rsa.privateKey,
        ),
    },
};

const out = join(import.meta.dirname, "kit_vectors.json");
writeFileSync(out, JSON.stringify(vectors, null, 2) + "\n");
console.log(`Wrote ${out} from kit commit ${commit}`);
