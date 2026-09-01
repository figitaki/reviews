//! Thin reqwest blocking wrapper around the Phoenix REST API.
//!
//! Endpoints (see docs/CONTRACTS.md):
//!   GET  /api/v1/me
//!   GET  /api/v1/capabilities
//!   POST /api/v1/reviews
//!   POST /api/v1/reviews/:slug/patchsets
//!   POST /api/v1/code-snapshots
//!   POST /api/v1/code-snapshots/:id/complete
//!   GET  /api/v1/reviews/:slug

use anyhow::{anyhow, Context, Result};
use reqwest::blocking::{Client, RequestBuilder, Response};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

/// A non-2xx API response, preserving the status and the server's stable
/// machine-readable `errors.code` (when present) so commands can branch on it
/// instead of parsing message text.
#[derive(Debug)]
pub struct ApiError {
    /// HTTP status, kept for future callers that branch on it.
    #[allow(dead_code)]
    pub status: u16,
    pub code: Option<String>,
    pub message: String,
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for ApiError {}

/// The stable error code from an anyhow error chain, if it wraps an ApiError.
pub fn api_error_code(err: &anyhow::Error) -> Option<&str> {
    err.downcast_ref::<ApiError>()
        .and_then(|e| e.code.as_deref())
}

pub struct ApiClient {
    base_url: String,
    token: Option<String>,
    http: Client,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Me {
    pub username: String,
    pub email: String,
    pub identity: Option<Identity>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Identity {
    pub id: i64,
    pub kind: String,
    pub handle: String,
    pub display_name: String,
    pub avatar_url: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CreateReviewRequest<'a> {
    pub title: &'a str,
    pub description: &'a str,
    pub base_sha: &'a str,
    pub branch_name: &'a str,
    pub raw_diff: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub packet: Option<&'a Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code_snapshot_id: Option<&'a str>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateReviewResponse {
    #[allow(dead_code)]
    pub id: i64,
    pub slug: String,
    pub url: String,
    pub patchset_number: i64,
    /// Absent when the push carried no snapshot id, and on old servers.
    #[serde(default)]
    pub code_snapshot: Option<CodeSnapshotResult>,
}

#[derive(Debug, Serialize)]
pub struct CreatePatchsetRequest<'a> {
    pub base_sha: &'a str,
    pub branch_name: &'a str,
    pub raw_diff: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub packet: Option<&'a Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code_snapshot_id: Option<&'a str>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreatePatchsetResponse {
    pub patchset_number: i64,
    pub url: String,
    /// Absent when the push carried no snapshot id, and on old servers.
    #[serde(default)]
    pub code_snapshot: Option<CodeSnapshotResult>,
}

/// The server's verdict on a `code_snapshot_id` claim: `claimed`, or
/// `skipped` with a stable error code under the optional storage policy.
#[derive(Debug, Clone, Deserialize)]
pub struct CodeSnapshotResult {
    pub status: String,
    #[serde(default)]
    pub code: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Capabilities {
    pub code_storage: CodeStorageCaps,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CodeStorageCaps {
    pub enabled: bool,
    pub required: bool,
    #[serde(default)]
    pub supported_object_formats: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct ReserveSnapshotRequest<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub review_slug: Option<&'a str>,
    pub object_format: &'a str,
    pub base_oid: &'a str,
    pub head_oid: &'a str,
    pub head_kind: &'a str,
}

#[derive(Clone, Deserialize)]
pub struct ReserveSnapshotResponse {
    pub id: String,
    #[allow(dead_code)]
    pub repository_id: String,
    pub upload: UploadInstructions,
    pub refs: SnapshotRefs,
}

#[derive(Clone, Deserialize)]
pub struct UploadInstructions {
    pub remote_url: String,
    pub token: String,
    #[allow(dead_code)]
    pub expires_at: String,
}

/// The upload credential must never be printed; keep it out of Debug output.
impl std::fmt::Debug for UploadInstructions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UploadInstructions")
            .field("remote_url", &self.remote_url)
            .field("token", &"[redacted]")
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct SnapshotRefs {
    pub base: String,
    pub head: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CompleteSnapshotResponse {
    #[allow(dead_code)]
    pub id: String,
    pub status: String,
}

#[derive(Debug, Serialize)]
pub struct CreateCommentRequest<'a> {
    pub file_path: &'a str,
    pub side: &'a str,
    pub body: &'a str,
    pub thread_anchor: Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateCommentResponse {
    pub thread_id: i64,
    pub comment_id: i64,
    pub url: String,
}

#[derive(Debug, Serialize)]
pub struct SectionDecisionRequest<'a> {
    pub status: &'a str,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SectionDecisionResponse {
    pub review: String,
    pub patchset_number: i64,
    pub section_index: i64,
    pub status: Option<String>,
}

impl ApiClient {
    pub fn new(base_url: impl Into<String>, token: impl Into<String>) -> Result<Self> {
        Self::build(base_url.into(), Some(token.into()))
    }

    pub fn anonymous(base_url: impl Into<String>) -> Result<Self> {
        Self::build(base_url.into(), None)
    }

    fn build(base_url: String, token: Option<String>) -> Result<Self> {
        let http = Client::builder()
            .timeout(Duration::from_secs(60))
            .user_agent(concat!("reviews-cli/", env!("CARGO_PKG_VERSION")))
            .build()
            .context("could not build HTTP client")?;
        Ok(ApiClient {
            base_url: base_url.trim_end_matches('/').to_string(),
            token,
            http,
        })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base_url, path)
    }

    fn auth(&self, req: RequestBuilder) -> RequestBuilder {
        match &self.token {
            Some(t) => req.bearer_auth(t),
            None => req,
        }
    }

    fn require_token(&self, what: &str) -> Result<&str> {
        self.token
            .as_deref()
            .ok_or_else(|| anyhow!("{what} requires an API token. Run `reviews login` first."))
    }

    /// Probe server capabilities. `Ok(None)` means an older server without
    /// the endpoint (HTTP 404) — treat every feature as disabled.
    pub fn capabilities(&self) -> Result<Option<Capabilities>> {
        let path = "/api/v1/capabilities";
        let resp = self
            .auth(self.http.get(self.url(path)))
            .send()
            .with_context(|| format!("could not reach server for GET {path}"))?;
        if resp.status() == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        let resp = check_status(resp, &format!("GET {path}"))?;
        let caps = resp
            .json::<Capabilities>()
            .with_context(|| format!("could not parse {path} response as JSON"))?;
        Ok(Some(caps))
    }

    pub fn reserve_snapshot(
        &self,
        req: &ReserveSnapshotRequest<'_>,
    ) -> Result<ReserveSnapshotResponse> {
        let path = "/api/v1/code-snapshots";
        let _ = self.require_token(&format!("POST {path}"))?;
        let resp = self
            .auth(self.http.post(self.url(path)))
            .json(req)
            .send()
            .with_context(|| format!("could not reach server for POST {path}"))?;
        let resp = check_status(resp, &format!("POST {path}"))?;
        resp.json::<ReserveSnapshotResponse>()
            .with_context(|| format!("could not parse {path} response as JSON"))
    }

    pub fn complete_snapshot(&self, id: &str) -> Result<CompleteSnapshotResponse> {
        let path = format!("/api/v1/code-snapshots/{id}/complete");
        let _ = self.require_token(&format!("POST {path}"))?;
        let resp = self
            .auth(self.http.post(self.url(&path)))
            .send()
            .with_context(|| format!("could not reach server for POST {path}"))?;
        let resp = check_status(resp, &format!("POST {path}"))?;
        resp.json::<CompleteSnapshotResponse>()
            .with_context(|| format!("could not parse {path} response as JSON"))
    }

    pub fn me(&self) -> Result<Me> {
        let _ = self.require_token("GET /api/v1/me")?;
        let resp = self
            .auth(self.http.get(self.url("/api/v1/me")))
            .send()
            .context("could not reach server for GET /api/v1/me")?;
        let resp = check_status(resp, "GET /api/v1/me")?;
        resp.json::<Me>()
            .context("could not parse /api/v1/me response as JSON")
    }

    pub fn create_review(&self, req: &CreateReviewRequest<'_>) -> Result<CreateReviewResponse> {
        let _ = self.require_token("POST /api/v1/reviews")?;
        let resp = self
            .auth(self.http.post(self.url("/api/v1/reviews")))
            .json(req)
            .send()
            .context("could not reach server for POST /api/v1/reviews")?;
        let resp = check_status(resp, "POST /api/v1/reviews")?;
        resp.json::<CreateReviewResponse>()
            .context("could not parse /api/v1/reviews response as JSON")
    }

    pub fn create_patchset(
        &self,
        slug: &str,
        req: &CreatePatchsetRequest<'_>,
    ) -> Result<CreatePatchsetResponse> {
        let path = format!("/api/v1/reviews/{slug}/patchsets");
        let _ = self.require_token(&format!("POST {path}"))?;
        let resp = self
            .auth(self.http.post(self.url(&path)))
            .json(req)
            .send()
            .with_context(|| format!("could not reach server for POST {path}"))?;
        let resp = check_status(resp, &format!("POST {path}"))?;
        resp.json::<CreatePatchsetResponse>()
            .with_context(|| format!("could not parse {path} response as JSON"))
    }

    pub fn create_comment(
        &self,
        slug: &str,
        req: &CreateCommentRequest<'_>,
    ) -> Result<CreateCommentResponse> {
        let path = format!("/api/v1/reviews/{slug}/comments");
        let _ = self.require_token(&format!("POST {path}"))?;
        let resp = self
            .auth(self.http.post(self.url(&path)))
            .json(req)
            .send()
            .with_context(|| format!("could not reach server for POST {path}"))?;
        let resp = check_status(resp, &format!("POST {path}"))?;
        resp.json::<CreateCommentResponse>()
            .with_context(|| format!("could not parse {path} response as JSON"))
    }

    pub fn show_review(&self, slug: &str, patchset: Option<i64>) -> Result<Value> {
        let path = format!("/api/v1/reviews/{slug}");
        let mut req = self.auth(self.http.get(self.url(&path)));
        if let Some(n) = patchset {
            req = req.query(&[("patchset", n.to_string())]);
        }
        let resp = req
            .send()
            .with_context(|| format!("could not reach server for GET {path}"))?;
        let resp = check_status(resp, &format!("GET {path}"))?;
        resp.json::<Value>()
            .with_context(|| format!("could not parse {path} response as JSON"))
    }

    pub fn set_section_decision(
        &self,
        slug: &str,
        section_index: i64,
        req: &SectionDecisionRequest<'_>,
    ) -> Result<SectionDecisionResponse> {
        let path = format!("/api/v1/reviews/{slug}/sections/{section_index}/decision");
        let _ = self.require_token(&format!("POST {path}"))?;
        let resp = self
            .auth(self.http.post(self.url(&path)))
            .json(req)
            .send()
            .with_context(|| format!("could not reach server for POST {path}"))?;
        let resp = check_status(resp, &format!("POST {path}"))?;
        resp.json::<SectionDecisionResponse>()
            .with_context(|| format!("could not parse {path} response as JSON"))
    }
}

fn check_status(resp: Response, what: &str) -> Result<Response> {
    let status = resp.status();
    if status.is_success() {
        return Ok(resp);
    }
    let body = resp.text().unwrap_or_default();
    let hint = match status {
        StatusCode::UNAUTHORIZED => {
            " — your API token was rejected. Mint a new one in /settings and run `reviews login`."
        }
        StatusCode::NOT_FOUND => " — the resource does not exist (check the slug?).",
        StatusCode::UNPROCESSABLE_ENTITY => " — server rejected the payload (validation error).",
        _ => "",
    };
    let code = serde_json::from_str::<Value>(&body)
        .ok()
        .and_then(|v| v["errors"]["code"].as_str().map(str::to_string));
    Err(anyhow::Error::new(ApiError {
        status: status.as_u16(),
        code,
        message: format!("{what} failed: HTTP {status}{hint}\nbody: {body}"),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn me_happy_path() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("GET", "/api/v1/me")
            .match_header("authorization", "Bearer tok")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"username":"careyjanecka","email":"carey@example.com","identity":{"id":1,"kind":"agent","handle":"codex","display_name":"Codex","avatar_url":null}}"#)
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let me = client.me().unwrap();
        assert_eq!(me.username, "careyjanecka");
        assert_eq!(me.email, "carey@example.com");
        assert_eq!(me.identity.unwrap().handle, "codex");
        mock.assert();
    }

    #[test]
    fn me_unauthorized_gives_helpful_message() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("GET", "/api/v1/me")
            .with_status(401)
            .with_body(r#"{"errors":{"detail":"Unauthorized"}}"#)
            .create();

        let client = ApiClient::new(server.url(), "bad").unwrap();
        let err = client.me().unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("401"), "msg = {msg}");
        assert!(msg.contains("reviews login"), "msg = {msg}");
    }

    #[test]
    fn create_review_happy_path() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("POST", "/api/v1/reviews")
            .match_header("authorization", "Bearer tok")
            .match_header("content-type", "application/json")
            .with_status(201)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{"id":42,"slug":"k7m2qz","url":"http://localhost:4000/r/k7m2qz","patchset_number":1}"#,
            )
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let resp = client
            .create_review(&CreateReviewRequest {
                title: "t",
                description: "d",
                base_sha: "deadbeef",
                branch_name: "main",
                raw_diff: "diff --git a/x b/x\n",
                packet: None,
                code_snapshot_id: None,
            })
            .unwrap();
        assert_eq!(resp.slug, "k7m2qz");
        assert_eq!(resp.patchset_number, 1);
        mock.assert();
    }

    #[test]
    fn create_patchset_happy_path() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("POST", "/api/v1/reviews/k7m2qz/patchsets")
            .match_header("authorization", "Bearer tok")
            .with_status(201)
            .with_header("content-type", "application/json")
            .with_body(r#"{"patchset_number":2,"url":"http://localhost:4000/r/k7m2qz"}"#)
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let resp = client
            .create_patchset(
                "k7m2qz",
                &CreatePatchsetRequest {
                    base_sha: "cafef00d",
                    branch_name: "main",
                    raw_diff: "diff --git a/x b/x\n",
                    packet: None,
                    code_snapshot_id: None,
                },
            )
            .unwrap();
        assert_eq!(resp.patchset_number, 2);
        mock.assert();
    }

    #[test]
    fn create_patchset_404_gives_helpful_message() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("POST", "/api/v1/reviews/nope/patchsets")
            .with_status(404)
            .with_body("{}")
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let err = client
            .create_patchset(
                "nope",
                &CreatePatchsetRequest {
                    base_sha: "x",
                    branch_name: "y",
                    raw_diff: "z",
                    packet: None,
                    code_snapshot_id: None,
                },
            )
            .unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("404"), "msg = {msg}");
        assert!(msg.contains("slug"), "msg = {msg}");
    }

    #[test]
    fn show_review_anonymous_returns_json() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("GET", "/api/v1/reviews/k7m2qz")
            .match_header("authorization", mockito::Matcher::Missing)
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"slug":"k7m2qz","title":"Hello","selected_patchset":{"number":1}}"#)
            .create();

        let client = ApiClient::anonymous(server.url()).unwrap();
        let body = client.show_review("k7m2qz", None).unwrap();
        assert_eq!(body["slug"], "k7m2qz");
        assert_eq!(body["selected_patchset"]["number"], 1);
        mock.assert();
    }

    #[test]
    fn show_review_with_patchset_passes_query_string() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("GET", "/api/v1/reviews/k7m2qz")
            .match_query(mockito::Matcher::UrlEncoded("patchset".into(), "2".into()))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"slug":"k7m2qz","selected_patchset":{"number":2}}"#)
            .create();

        let client = ApiClient::anonymous(server.url()).unwrap();
        let body = client.show_review("k7m2qz", Some(2)).unwrap();
        assert_eq!(body["selected_patchset"]["number"], 2);
        mock.assert();
    }

    #[test]
    fn create_comment_happy_path() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("POST", "/api/v1/reviews/k7m2qz/comments")
            .match_header("authorization", "Bearer tok")
            .match_header("content-type", "application/json")
            .with_status(201)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{"thread_id":7,"comment_id":12,"file_path":"foo","side":"new","anchor":{"granularity":"line"},"url":"http://localhost:4000/r/k7m2qz"}"#,
            )
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let anchor = serde_json::json!({"granularity": "line", "line_number_hint": 1});
        let resp = client
            .create_comment(
                "k7m2qz",
                &CreateCommentRequest {
                    file_path: "foo",
                    side: "new",
                    body: "lgtm",
                    thread_anchor: anchor,
                },
            )
            .unwrap();
        assert_eq!(resp.thread_id, 7);
        assert_eq!(resp.comment_id, 12);
        assert_eq!(resp.url, "http://localhost:4000/r/k7m2qz");
        mock.assert();
    }

    #[test]
    fn create_comment_requires_token() {
        let client = ApiClient::anonymous("http://example.invalid").unwrap();
        let err = client
            .create_comment(
                "x",
                &CreateCommentRequest {
                    file_path: "f",
                    side: "new",
                    body: "b",
                    thread_anchor: serde_json::json!({"granularity": "line"}),
                },
            )
            .unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("reviews login"), "msg = {msg}");
    }

    #[test]
    fn set_section_decision_happy_path() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("POST", "/api/v1/reviews/k7m2qz/sections/1/decision")
            .match_header("authorization", "Bearer tok")
            .match_header("content-type", "application/json")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{"review":"k7m2qz","patchset_number":2,"section_index":1,"status":"approved"}"#,
            )
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let resp = client
            .set_section_decision("k7m2qz", 1, &SectionDecisionRequest { status: "approved" })
            .unwrap();
        assert_eq!(resp.review, "k7m2qz");
        assert_eq!(resp.status.as_deref(), Some("approved"));
        mock.assert();
    }

    #[test]
    fn capabilities_404_means_old_server() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("GET", "/api/v1/capabilities")
            .with_status(404)
            .create();

        let client = ApiClient::anonymous(server.url()).unwrap();
        assert!(client.capabilities().unwrap().is_none());
    }

    #[test]
    fn capabilities_parse() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("GET", "/api/v1/capabilities")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{"code_storage":{"enabled":true,"required":false,"supported_object_formats":["sha1"],"max_upload_bytes":1},"lsp":{"enabled":false,"languages":[]}}"#,
            )
            .create();

        let client = ApiClient::anonymous(server.url()).unwrap();
        let caps = client.capabilities().unwrap().unwrap();
        assert!(caps.code_storage.enabled);
        assert!(!caps.code_storage.required);
        assert_eq!(caps.code_storage.supported_object_formats, vec!["sha1"]);
    }

    #[test]
    fn reserve_and_complete_snapshot_happy_path() {
        let mut server = mockito::Server::new();
        let reserve = server
            .mock("POST", "/api/v1/code-snapshots")
            .match_header("authorization", "Bearer tok")
            .match_body(mockito::Matcher::PartialJson(serde_json::json!({
                "object_format": "sha1",
                "head_kind": "commit"
            })))
            .with_status(201)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{"id":"snap-1","repository_id":"repo-1","expires_at":"x",
                    "upload":{"remote_url":"https://acme.code.storage/reviews/r.git","token":"jwt","expires_at":"y"},
                    "refs":{"base":"refs/heads/snapshots/snap-1/base","head":"refs/heads/snapshots/snap-1/head"}}"#,
            )
            .create();
        let complete = server
            .mock("POST", "/api/v1/code-snapshots/snap-1/complete")
            .match_header("authorization", "Bearer tok")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"id":"snap-1","status":"ready","base_oid":"a","head_oid":"b"}"#)
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let resp = client
            .reserve_snapshot(&ReserveSnapshotRequest {
                review_slug: None,
                object_format: "sha1",
                base_oid: "a",
                head_oid: "b",
                head_kind: "commit",
            })
            .unwrap();
        assert_eq!(resp.id, "snap-1");
        assert_eq!(resp.refs.base, "refs/heads/snapshots/snap-1/base");

        let done = client.complete_snapshot("snap-1").unwrap();
        assert_eq!(done.status, "ready");
        reserve.assert();
        complete.assert();
    }

    #[test]
    fn api_error_carries_stable_code() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("POST", "/api/v1/code-snapshots/x/complete")
            .with_status(422)
            .with_header("content-type", "application/json")
            .with_body(r#"{"errors":{"detail":"mismatch","code":"ref_mismatch"}}"#)
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let err = client.complete_snapshot("x").unwrap_err();
        assert_eq!(api_error_code(&err), Some("ref_mismatch"));
    }

    #[test]
    fn upload_instructions_debug_redacts_token() {
        let upload = UploadInstructions {
            remote_url: "https://x".to_string(),
            token: "super-secret".to_string(),
            expires_at: "z".to_string(),
        };
        let debug = format!("{upload:?}");
        assert!(!debug.contains("super-secret"), "debug = {debug}");
        assert!(debug.contains("[redacted]"));
    }

    #[test]
    fn create_review_omits_code_snapshot_id_when_none() {
        let req = CreateReviewRequest {
            title: "t",
            description: "",
            base_sha: "a",
            branch_name: "b",
            raw_diff: "d",
            packet: None,
            code_snapshot_id: None,
        };
        let json = serde_json::to_value(&req).unwrap();
        assert!(json.get("code_snapshot_id").is_none());

        let req = CreateReviewRequest {
            code_snapshot_id: Some("snap-1"),
            ..req
        };
        let json = serde_json::to_value(&req).unwrap();
        assert_eq!(json["code_snapshot_id"], "snap-1");
    }

    #[test]
    fn create_patchset_parses_code_snapshot_result() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("POST", "/api/v1/reviews/k7m2qz/patchsets")
            .with_status(201)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{"patchset_number":2,"url":"http://localhost:4000/r/k7m2qz",
                    "code_snapshot":{"status":"skipped","code":"snapshot_not_ready"}}"#,
            )
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let resp = client
            .create_patchset(
                "k7m2qz",
                &CreatePatchsetRequest {
                    base_sha: "x",
                    branch_name: "y",
                    raw_diff: "z",
                    packet: None,
                    code_snapshot_id: Some("snap-1"),
                },
            )
            .unwrap();
        let cs = resp.code_snapshot.unwrap();
        assert_eq!(cs.status, "skipped");
        assert_eq!(cs.code.as_deref(), Some("snapshot_not_ready"));
    }

    #[test]
    fn show_review_404_bubbles_up() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("GET", "/api/v1/reviews/nope")
            .with_status(404)
            .with_body(r#"{"errors":{"detail":"Review not found"}}"#)
            .create();

        let client = ApiClient::anonymous(server.url()).unwrap();
        let err = client.show_review("nope", None).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("404"), "msg = {msg}");
    }
}
