#!/usr/bin/env node
// A minimal Poppy 1.0 Personal Agent for trying Reviews as a Poppy Company.
// Node 20+, no dependencies. See README.md.
//
//   node poppy-agent.mjs keygen --base-url https://you.example/agent
//   node poppy-agent.mjs sign-in https://reviews.example
//   node poppy-agent.mjs get https://reviews.example /api/poppy/v1/reviews/<slug>
//   node poppy-agent.mjs comment https://reviews.example <slug> --file lib/a.ex --line 3 --body "Looks good"
//   node poppy-agent.mjs sign-out https://reviews.example
//
// Keys, tokens, and User IDs live in --dir (default .poppy-agent), mode 0600. They are secrets:
// keep them out of a model's context (spec 10.2).

import { createServer } from "node:http"
import { lookup } from "node:dns/promises"
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs"
import { join } from "node:path"
import { webcrypto as crypto } from "node:crypto"

const VERSION = "1.0"
const EC = { name: "ECDSA", namedCurve: "P-256" }
const SIGN = { name: "ECDSA", hash: "SHA-256" }

const [command, ...rest] = process.argv.slice(2)
const { positional, flags } = parseArgs(rest)
const dir = flags.dir || ".poppy-agent"

const b64 = (bytes) => Buffer.from(bytes).toString("base64url")
const enc = (value) => b64(Buffer.from(typeof value === "string" ? value : JSON.stringify(value)))
const randomId = (n = 16) => b64(crypto.getRandomValues(new Uint8Array(n)))
const now = () => Math.floor(Date.now() / 1000)
const sha256 = async (s) => b64(await crypto.subtle.digest("SHA-256", Buffer.from(s)))

function parseArgs(args) {
  const positional = []
  const flags = {}
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith("--")) {
      const key = args[i].slice(2)
      const next = args[i + 1]
      if (next === undefined || next.startsWith("--")) flags[key] = true
      else flags[key] = args[++i]
    } else positional.push(args[i])
  }
  return { positional, flags }
}

function load(name) {
  const path = join(dir, name)
  return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : null
}

function save(name, value) {
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  writeFileSync(join(dir, name), JSON.stringify(value, null, 2) + "\n", { mode: 0o600 })
}

async function thumbprint({ crv, kty, x, y }) {
  return sha256(JSON.stringify({ crv, kty, x, y }))
}

async function signJwt(header, payload, privateKey) {
  const input = `${enc(header)}.${enc(payload)}`
  // WebCrypto ECDSA signatures are r || s, the JWS form for ES256.
  const sig = await crypto.subtle.sign(SIGN, privateKey, Buffer.from(input))
  return `${input}.${b64(sig)}`
}

async function importRoot() {
  const jwk = load("private-key.jwk")
  if (!jwk) throw new Error(`No key in ${dir}. Run keygen first.`)
  const key = await crypto.subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y, d: jwk.d }, EC, false, ["sign"])
  return { key, kid: jwk.kid }
}

// The spec forbids connecting to loopback, private, or link-local addresses for URLs another
// party gave us unless configured on purpose (spec 3). --allow-private-addresses is that.
async function checkAddress(url) {
  if (flags["allow-private-addresses"]) return
  const { host } = new URL(url)
  for (const { address } of await lookup(host.replace(/^\[|\]$/g, ""), { all: true })) {
    if (/^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|0\.|::1$|f[cd]|fe[89ab])/i.test(address)) {
      throw new Error(`${host} resolves to ${address}, a private address. Pass --allow-private-addresses to test locally.`)
    }
  }
}

async function getJson(url) {
  if (!url.startsWith("https://")) throw new Error(`Not an HTTPS URL: ${url}`)
  await checkAddress(url)
  const res = await fetch(url, { redirect: "error", headers: { accept: "application/json" } })
  if (!res.ok) throw new Error(`GET ${url}: HTTP ${res.status}`)
  return res.json()
}

// Discovery (spec 3, 3.2): poppy.json speaks for the host that serves it, the domain's
// protected resource metadata names the issuer, and the issuer lists the domain back.
async function discover(companyUrl) {
  const origin = new URL(companyUrl).origin
  const poppy = await getJson(`${origin}/.well-known/poppy.json`)
  const domain = new URL(origin).host
  if (poppy.organization?.domain?.toLowerCase() !== domain.toLowerCase()) throw new Error("organization.domain isn't the host that served poppy.json")
  if (!String(poppy.protocol_version).startsWith("1.")) throw new Error(`Unsupported protocol_version ${poppy.protocol_version}`)
  const resource = await getJson(`${origin}/.well-known/oauth-protected-resource`)
  if (resource.resource !== `https://${domain}`) throw new Error("Protected resource metadata is for another resource")
  const issuer = poppy.auth?.issuer || resource.authorization_servers?.[0]
  if (!issuer) return { poppy, domain, identifier: `https://${domain.toLowerCase()}` }
  const issuerUrl = new URL(issuer)
  const metadataPath = `/.well-known/oauth-authorization-server${issuerUrl.pathname === "/" ? "" : issuerUrl.pathname}`
  const as = await getJson(`${issuerUrl.origin}${metadataPath}`)
  if (as.issuer !== issuer) throw new Error("Issuer metadata names another issuer")
  if (!as.protected_resources?.includes(`https://${domain}`)) throw new Error("The issuer doesn't list this domain")
  return { poppy, domain, issuer, identifier: issuer, as }
}

async function clientAssertion(state, issuer) {
  const root = await importRoot()
  const iat = now()
  return signJwt(
    { alg: "ES256", typ: "JWT", kid: root.kid },
    { iss: state.client_id, sub: state.client_id, aud: issuer, iat, exp: iat + 120, jti: randomId() },
    root.key,
  )
}

async function tokenRequest(state, company, params) {
  await checkAddress(company.as.token_endpoint)
  const body = new URLSearchParams({
    ...params,
    client_id: state.client_id,
    client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
    client_assertion: await clientAssertion(state, company.issuer),
  })
  const res = await fetch(company.as.token_endpoint, { method: "POST", body, redirect: "error" })
  const json = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(`Token endpoint: ${json.error || res.status}`)
  return json
}

// One delegated key per run, for one User ID (spec 5.2), vouched for by the root key.
let delegated
async function delegatedKey(state) {
  if (delegated) return delegated
  const pair = await crypto.subtle.generateKey(EC, true, ["sign", "verify"])
  const { kty, crv, x, y } = await crypto.subtle.exportKey("jwk", pair.publicKey)
  const root = await importRoot()
  const iat = now()
  const delegation = await signJwt(
    { alg: "ES256", typ: "poppy-delegation+jwt", kid: root.kid },
    { iss: state.client_id, cnf: { jwk: { kty, crv, x, y } }, iat, exp: iat + 3600, jti: randomId() },
    root.key,
  )
  delegated = { key: pair.privateKey, kid: await thumbprint({ kty, crv, x, y }), delegation }
  return delegated
}

async function poppyRequest(state, company, method, url, { accessToken, body, sid } = {}) {
  await checkAddress(url)
  const user = (state.user_ids[company.identifier] ||= `usr_${randomId()}`)
  save("state.json", state)
  const key = await delegatedKey(state)
  const u = new URL(url)
  const claims = {
    iss: state.client_id,
    aud: company.identifier,
    sid,
    sub: user,
    htm: method,
    htu: `${u.origin}${u.pathname}`,
    iat: now(),
    jti: randomId(),
  }
  if (accessToken) claims.ath = await sha256(accessToken)
  const jwt = await signJwt({ typ: "poppy-session+jwt", alg: "ES256", kid: key.kid, poppy_dlg: key.delegation }, claims, key.key)
  const headers = { "Poppy-Session": jwt, "Poppy-Version": VERSION, accept: "application/json" }
  if (accessToken) headers.authorization = `Bearer ${accessToken}`
  if (body) headers["content-type"] = "application/json"
  const res = await fetch(url, { method, headers, body: body && JSON.stringify(body), redirect: "manual" })
  const text = await res.text()
  let json
  try { json = JSON.parse(text) } catch { json = text }
  return { status: res.status, json, challenge: res.headers.get("www-authenticate") }
}

async function keygen() {
  const base = String(flags["base-url"] || "").replace(/\/+$/, "")
  if (!base.startsWith("https://")) throw new Error("--base-url must be an HTTPS URL where you will host agent.json and jwks.json")
  if (load("private-key.jwk") && !flags.force) throw new Error(`${dir} already has a key. Pass --force to replace it.`)
  const pair = await crypto.subtle.generateKey(EC, true, ["sign", "verify"])
  const priv = await crypto.subtle.exportKey("jwk", pair.privateKey)
  const kid = (await thumbprint(priv)).slice(0, 16)
  const client_id = `${base}/agent.json`
  save("private-key.jwk", { kty: "EC", crv: "P-256", x: priv.x, y: priv.y, d: priv.d, kid })
  save("agent.json", {
    client_id,
    client_name: flags.name || "Poppy example agent",
    jwks_uri: `${base}/jwks.json`,
    redirect_uris: ["http://127.0.0.1/callback"],
    token_endpoint_auth_method: "private_key_jwt",
  })
  save("jwks.json", { keys: [{ kty: "EC", crv: "P-256", x: priv.x, y: priv.y, kid, alg: "ES256", use: "sig" }] })
  save("state.json", { client_id, user_ids: {}, tokens: {} })
  console.log(`Host ${join(dir, "agent.json")} at ${client_id}\nand ${join(dir, "jwks.json")} at ${base}/jwks.json, without redirects.`)
}

// Direct Sign-In (spec 4.2) with a loopback redirect, so a forwarded link fails.
async function signIn(companyUrl) {
  const state = load("state.json")
  const company = await discover(companyUrl)
  if (!company.issuer) throw new Error("This Company offers no sign-in.")
  const verifier = randomId(32)
  const challenge = await sha256(verifier)
  const oauthState = randomId()
  const server = createServer()
  await new Promise((ok) => server.listen(0, "127.0.0.1", ok))
  const redirectUri = `http://127.0.0.1:${server.address().port}/callback`
  const authorize = new URL(company.as.authorization_endpoint)
  authorize.search = new URLSearchParams({
    response_type: "code",
    client_id: state.client_id,
    redirect_uri: redirectUri,
    scope: flags.scope || "comments:write",
    state: oauthState,
    code_challenge: challenge,
    code_challenge_method: "S256",
  })
  console.log(`Open this link in your browser to approve ${company.domain}:\n\n${authorize}\n`)

  const query = await new Promise((resolve) => {
    server.on("request", (req, res) => {
      const q = new URL(req.url, redirectUri).searchParams
      res.setHeader("connection", "close")
      res.end("You can close this tab and return to your agent.")
      server.close()
      server.closeAllConnections()
      resolve(q)
    })
  })
  if (query.get("iss") !== company.issuer) throw new Error("The redirect came from another issuer (RFC 9207).")
  if (query.get("state") !== oauthState) throw new Error("State mismatch.")
  if (query.get("error")) throw new Error(`Sign-in ended: ${query.get("error")}`)

  const tokens = await tokenRequest(state, company, {
    grant_type: "authorization_code",
    code: query.get("code"),
    redirect_uri: redirectUri,
    code_verifier: verifier,
  })
  state.tokens[company.issuer] = { ...tokens, obtained_at: now() }
  save("state.json", state)
  console.log(`Signed in to ${company.domain} with scopes: ${tokens.scope}`)
}

async function accessToken(state, company, { force = false } = {}) {
  const saved = state.tokens[company.issuer]
  if (!saved) throw new Error("Not signed in. Run sign-in first.")
  if (!force && saved.obtained_at + saved.expires_in - 30 > now()) return saved.access_token
  const refreshed = await tokenRequest(state, company, { grant_type: "refresh_token", refresh_token: saved.refresh_token })
  state.tokens[company.issuer] = { ...saved, ...refreshed, obtained_at: now() }
  save("state.json", state)
  return refreshed.access_token
}

function apiBase(company) {
  const api = company.poppy.apis?.find((a) => a.type === "openapi")
  if (!api) throw new Error("The Company lists no OpenAPI description.")
  return api
}

async function main() {
  const state = load("state.json")
  switch (command) {
    case "keygen":
      return keygen()
    case "sign-in":
      return signIn(positional[0])
    case "get": {
      const company = await discover(positional[0])
      const url = new URL(positional[1], positional[0]).toString()
      const res = await poppyRequest(state, company, "GET", url, { sid: randomId() })
      return console.log(res.status, JSON.stringify(res.json, null, 2).slice(0, 2000))
    }
    case "comment": {
      const company = await discover(positional[0])
      const openapi = await getJson(apiBase(company).url)
      const url = `${openapi.servers[0].url}/reviews/${encodeURIComponent(positional[1])}/comments`
      const body = {
        file_path: flags.file,
        side: flags.side || "new",
        body: flags.body,
        thread_anchor: { granularity: "line", line_number_hint: Number(flags.line) },
      }
      const sid = randomId()
      let res = await poppyRequest(state, company, "POST", url, { accessToken: await accessToken(state, company), body, sid })
      if (res.status === 401 && /invalid_token/.test(res.challenge || "")) {
        res = await poppyRequest(state, company, "POST", url, { accessToken: await accessToken(state, company, { force: true }), body, sid })
      }
      return console.log(res.status, JSON.stringify(res.json, null, 2))
    }
    case "sign-out": {
      const company = await discover(positional[0])
      const saved = state.tokens[company.issuer]
      if (!saved) return console.log("Not signed in.")
      await checkAddress(company.as.revocation_endpoint)
      const body = new URLSearchParams({
        token: saved.refresh_token,
        token_type_hint: "refresh_token",
        client_id: state.client_id,
        client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        client_assertion: await clientAssertion(state, company.issuer),
      })
      const res = await fetch(company.as.revocation_endpoint, { method: "POST", body, redirect: "error" })
      delete state.tokens[company.issuer]
      save("state.json", state)
      return console.log(res.ok ? "Signed out." : `Revocation failed: HTTP ${res.status}`)
    }
    default:
      console.log("Commands: keygen, sign-in, get, comment, sign-out. See README.md.")
  }
}

main().catch((error) => {
  console.error(error.message)
  process.exit(1)
})
