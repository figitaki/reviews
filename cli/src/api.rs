//! Thin reqwest blocking wrapper around the Phoenix REST API.
//!
//! Endpoints (see docs/CONTRACTS.md):
//!   GET  /api/v1/me
//!   GET  /api/v1/capabilities
//!   GET  /api/v1/reviews
//!   POST /api/v1/reviews
//!   POST /api/v1/reviews/:slug/patchsets
//!   POST /api/v1/code-snapshots
//!   POST /api/v1/code-snapshots/:id/complete
//!   GET  /api/v1/reviews/:slug
//!   POST /api/v1/reviews/:slug/comments (new thread or reply)
//!   PATCH /api/v1/reviews/:slug/threads/:thread_id
//!   POST /api/v1/reviews/:slug/sections/:section_index/decision
//!   GET  /api/v1/reviews/:slug/deletion
//!   DELETE /api/v1/reviews/:slug

use anyhow::{anyhow, Context, Result};
use reqwest::blocking::{Client, RequestBuilder, Response};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

/// A non-2xx API response, preserving the status and the server's stable
/// machine-readable `error_code` (when present) so commands can branch on it
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
    /// Null when the GitHub account has no public email.
    pub email: Option<String>,
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
    /// Files `.gitattributes` marks generated or vendored; empty is omitted.
    #[serde(skip_serializing_if = "<[_]>::is_empty")]
    pub file_attributes: &'a [crate::git::FileAttributes],
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
    /// Files `.gitattributes` marks generated or vendored; empty is omitted.
    #[serde(skip_serializing_if = "<[_]>::is_empty")]
    pub file_attributes: &'a [crate::git::FileAttributes],
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_path: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub side: Option<&'a str>,
    pub body: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread_anchor: Option<Value>,
    /// Exact revision number for a new thread; omitted selects latest.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread_id: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateCommentResponse {
    pub thread_id: i64,
    pub comment_id: i64,
    pub url: String,
}

#[derive(Debug, Serialize)]
pub struct UpdateThreadStatusRequest<'a> {
    pub status: &'a str,
}

#[derive(Debug, Serialize)]
pub struct SectionDecisionRequest<'a> {
    pub status: &'a str,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdateThreadStatusResponse {
    pub id: i64,
    pub status: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SectionDecisionResponse {
    pub review: String,
    pub patchset_number: i64,
    pub section_index: i64,
    pub status: Option<String>,
}

/// What deleting a review would remove (`GET /api/v1/reviews/:slug/deletion`).
#[derive(Debug, Clone, Deserialize)]
pub struct DeletionPreview {
    pub slug: String,
    pub title: String,
    pub patchsets: i64,
    pub threads: i64,
    pub comments: i64,
    pub other_comments: i64,
    pub other_authors: Vec<String>,
}

/// Filters for `GET /api/v1/reviews`. `None` fields are left out of the query.
#[derive(Debug, Default, Clone, Serialize)]
pub struct ListReviewsQuery {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub q: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub offset: Option<u32>,
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
            .ok_or_else(|| anyhow!("{what} requires you to sign in. Run `reviews login` first."))
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

    pub fn update_thread_status(
        &self,
        slug: &str,
        thread_id: i64,
        req: &UpdateThreadStatusRequest<'_>,
    ) -> Result<UpdateThreadStatusResponse> {
        let path = format!("/api/v1/reviews/{slug}/threads/{thread_id}");
        let _ = self.require_token(&format!("PATCH {path}"))?;
        let resp = self
            .auth(self.http.patch(self.url(&path)))
            .json(req)
            .send()
            .with_context(|| format!("could not reach server for PATCH {path}"))?;
        let resp = check_status(resp, &format!("PATCH {path}"))?;
        resp.json::<UpdateThreadStatusResponse>()
            .with_context(|| format!("could not parse {path} response as JSON"))
    }

    pub fn list_reviews(&self, query: &ListReviewsQuery) -> Result<Value> {
        let path = "/api/v1/reviews";
        let _ = self.require_token(&format!("GET {path}"))?;
        let resp = self
            .auth(self.http.get(self.url(path)))
            .query(query)
            .send()
            .with_context(|| format!("could not reach server for GET {path}"))?;
        let resp = check_status(resp, &format!("GET {path}"))?;
        resp.json::<Value>()
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

    pub fn deletion_preview(&self, slug: &str) -> Result<DeletionPreview> {
        let path = format!("/api/v1/reviews/{slug}/deletion");
        let _ = self.require_token(&format!("GET {path}"))?;
        let resp = self
            .auth(self.http.get(self.url(&path)))
            .send()
            .with_context(|| format!("could not reach server for GET {path}"))?;
        let resp = check_status(resp, &format!("GET {path}"))?;
        resp.json::<DeletionPreview>()
            .with_context(|| format!("could not parse {path} response as JSON"))
    }

    pub fn delete_review(&self, slug: &str) -> Result<()> {
        let path = format!("/api/v1/reviews/{slug}");
        let _ = self.require_token(&format!("DELETE {path}"))?;
        let resp = self
            .auth(self.http.delete(self.url(&path)))
            .send()
            .with_context(|| format!("could not reach server for DELETE {path}"))?;
        check_status(resp, &format!("DELETE {path}"))?;
        Ok(())
    }
}

fn check_status(resp: Response, what: &str) -> Result<Response> {
    let status = resp.status();
    if status.is_success() {
        return Ok(resp);
    }
    let body = resp.text().unwrap_or_default();
    let parsed = serde_json::from_str::<Value>(&body).ok();
    let code = parsed
        .as_ref()
        .and_then(|v| v.get("error_code"))
        .and_then(Value::as_str);
    let hint = match code {
        Some("invalid_anchor") => " — choose a line or token selection in the selected revision.",
        Some("patchset_not_found") => " — select a revision that belongs to this review.",
        Some("review_deleted") => " — this review was deleted.",
        _ => match status {
        StatusCode::UNAUTHORIZED => {
            " — the server rejected your sign-in. Run `reviews login` again."
        }
        StatusCode::FORBIDDEN => {
            " — this identity is not allowed to do that on this review. Only the review owner can push revisions, decide sections or delete the review; the owner or the thread's author can resolve or reopen a thread."
        }
        StatusCode::NOT_FOUND => " — the resource does not exist (check the slug?).",
        StatusCode::UNPROCESSABLE_ENTITY => " — server rejected the payload (validation error).",
        StatusCode::BAD_REQUEST => " — the server did not accept a parameter. See the body.",
        _ => "",
    },
    };
    let code_label = code.map(|c| format!(" [{c}]")).unwrap_or_default();
    Err(anyhow::Error::new(ApiError {
        status: status.as_u16(),
        code: code.map(str::to_string),
        message: format!("{what} failed: HTTP {status}{code_label}{hint}\nbody: {body}"),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_stable_error_code_from_server_fixture() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("GET", "/api/v1/me")
            .with_status(422)
            .with_body(include_str!("../../test/vectors/api/invalid-anchor.json"))
            .create();
        let client = ApiClient::new(server.url(), "tok").unwrap();
        let error = format!("{}", client.me().unwrap_err());
        assert!(error.contains("[invalid_anchor]"));
        assert!(error.contains("choose a line or token selection"));
        mock.assert();
    }

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
        assert_eq!(me.email.as_deref(), Some("carey@example.com"));
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
    fn forbidden_explains_who_may_act() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("PATCH", "/api/v1/reviews/k7m2qz/threads/7")
            .with_status(403)
            .with_body(r#"{"errors":{"detail":"Only the review owner or the thread's author can resolve or reopen it"}}"#)
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let err = client
            .update_thread_status(
                "k7m2qz",
                7,
                &UpdateThreadStatusRequest { status: "resolved" },
            )
            .unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("403"), "msg = {msg}");
        assert!(msg.contains("review owner"), "msg = {msg}");
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
                file_attributes: &[],
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
                    file_attributes: &[],
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
                    file_attributes: &[],
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
                    file_path: Some("foo"),
                    side: Some("new"),
                    body: "lgtm",
                    thread_anchor: Some(anchor),
                    thread_id: None,
                    revision: None,
                },
            )
            .unwrap();
        assert_eq!(resp.thread_id, 7);
        assert_eq!(resp.comment_id, 12);
        assert_eq!(resp.url, "http://localhost:4000/r/k7m2qz");
        mock.assert();
    }

    #[test]
    fn reply_posts_only_thread_and_body_without_get() {
        let mut server = mockito::Server::new();
        let get = server.mock("GET", mockito::Matcher::Any).expect(0).create();
        let post = server
            .mock("POST", "/api/v1/reviews/slug/comments")
            .match_body(mockito::Matcher::Json(
                serde_json::json!({"thread_id": 7, "body": "reply"}),
            ))
            .with_status(201)
            .with_header("content-type", "application/json")
            .with_body(r#"{"thread_id":7,"comment_id":8,"url":"http://localhost/r/slug"}"#)
            .create();
        let client = ApiClient::new(server.url(), "tok").unwrap();
        client
            .create_comment(
                "slug",
                &CreateCommentRequest {
                    file_path: None,
                    side: None,
                    body: "reply",
                    thread_anchor: None,
                    thread_id: Some(7),
                    revision: None,
                },
            )
            .unwrap();
        post.assert();
        get.assert();
    }

    #[test]
    fn comment_serializes_exact_revision() {
        let req = CreateCommentRequest {
            file_path: Some("foo"),
            side: Some("new"),
            body: "comment",
            thread_anchor: Some(serde_json::json!({"granularity":"line", "line_number_hint":1})),
            thread_id: None,
            revision: Some(2),
        };
        assert_eq!(serde_json::to_value(req).unwrap()["revision"], 2);
    }

    #[test]
    fn create_comment_requires_token() {
        let client = ApiClient::anonymous("http://example.invalid").unwrap();
        let err = client
            .create_comment(
                "x",
                &CreateCommentRequest {
                    file_path: Some("f"),
                    side: Some("new"),
                    body: "b",
                    thread_anchor: Some(serde_json::json!({"granularity": "line"})),
                    thread_id: None,
                    revision: None,
                },
            )
            .unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("reviews login"), "msg = {msg}");
    }

    #[test]
    fn update_thread_status_happy_path() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("PATCH", "/api/v1/reviews/k7m2qz/threads/7")
            .match_header("authorization", "Bearer tok")
            .match_header("content-type", "application/json")
            .match_body(r#"{"status":"resolved"}"#)
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"id":7,"status":"resolved"}"#)
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let resp = client
            .update_thread_status(
                "k7m2qz",
                7,
                &UpdateThreadStatusRequest { status: "resolved" },
            )
            .unwrap();

        assert_eq!(resp.id, 7);
        assert_eq!(resp.status, "resolved");
        mock.assert();
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
            .with_body(r#"{"errors":{"detail":"mismatch"},"error_code":"ref_mismatch","error_detail":"mismatch"}"#)
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
            file_attributes: &[],
        };
        let json = serde_json::to_value(&req).unwrap();
        assert!(json.get("code_snapshot_id").is_none());
        assert!(json.get("file_attributes").is_none());

        let attrs = [crate::git::FileAttributes {
            path: "Cargo.lock".into(),
            generated: true,
            vendored: false,
        }];
        let with_attrs = CreateReviewRequest {
            file_attributes: &attrs,
            ..req
        };
        let json = serde_json::to_value(&with_attrs).unwrap();
        assert_eq!(
            json["file_attributes"],
            serde_json::json!([{"path": "Cargo.lock", "generated": true, "vendored": false}])
        );
        let req = CreateReviewRequest {
            file_attributes: &[],
            ..with_attrs
        };

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
                    file_attributes: &[],
                },
            )
            .unwrap();
        let cs = resp.code_snapshot.unwrap();
        assert_eq!(cs.status, "skipped");
        assert_eq!(cs.code.as_deref(), Some("snapshot_not_ready"));
    }

    #[test]
    fn list_reviews_sends_filters_and_token() {
        let mut server = mockito::Server::new();
        let mock = server
            .mock("GET", "/api/v1/reviews")
            .match_header("authorization", "Bearer tok")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("role".into(), "involved".into()),
                mockito::Matcher::UrlEncoded("q".into(), "billing export".into()),
                mockito::Matcher::UrlEncoded("limit".into(), "5".into()),
            ]))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"reviews":[],"limit":5,"offset":0,"next_offset":null}"#)
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let body = client
            .list_reviews(&ListReviewsQuery {
                role: Some("involved".into()),
                q: Some("billing export".into()),
                limit: Some(5),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(body["limit"], 5);
        mock.assert();
    }

    #[test]
    fn list_reviews_requires_token() {
        let client = ApiClient::anonymous("http://example.invalid").unwrap();
        let err = client
            .list_reviews(&ListReviewsQuery::default())
            .unwrap_err();
        assert!(format!("{err:#}").contains("reviews login"));
    }

    #[test]
    fn list_reviews_400_shows_hint() {
        let mut server = mockito::Server::new();
        let _mock = server
            .mock("GET", "/api/v1/reviews")
            .match_query(mockito::Matcher::Any)
            .with_status(400)
            .with_body(r#"{"errors":{"role":"must be one of: all, authored, involved"}}"#)
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let err = client
            .list_reviews(&ListReviewsQuery::default())
            .unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("400"), "msg = {msg}");
        assert!(msg.contains("must be one of"), "msg = {msg}");
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
