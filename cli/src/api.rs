//! Thin reqwest blocking wrapper around the Phoenix REST API.
//!
//! Endpoints (see docs/CONTRACTS.md):
//!   GET  /api/v1/me
//!   POST /api/v1/reviews
//!   POST /api/v1/reviews/:slug/patchsets
//!   GET  /api/v1/reviews/:slug
//!   POST /api/v1/reviews/:slug/comments (new thread or reply)
//!   PATCH /api/v1/reviews/:slug/threads/:thread_id
//!   POST /api/v1/reviews/:slug/sections/:section_index/decision

use anyhow::{anyhow, Context, Result};
use reqwest::blocking::{Client, RequestBuilder, Response};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

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
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateReviewResponse {
    #[allow(dead_code)]
    pub id: i64,
    pub slug: String,
    pub url: String,
    pub patchset_number: i64,
}

#[derive(Debug, Serialize)]
pub struct CreatePatchsetRequest<'a> {
    pub base_sha: &'a str,
    pub branch_name: &'a str,
    pub raw_diff: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub packet: Option<&'a Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreatePatchsetResponse {
    pub patchset_number: i64,
    pub url: String,
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
    let parsed = serde_json::from_str::<Value>(&body).ok();
    let code = parsed
        .as_ref()
        .and_then(|v| v.get("error_code"))
        .and_then(Value::as_str);
    let hint = match code {
        Some("invalid_anchor") => " — choose a line or token selection in the selected revision.",
        Some("patchset_not_found") => " — select a revision that belongs to this review.",
        _ => match status {
        StatusCode::UNAUTHORIZED => {
            " — your API token was rejected. Mint a new one in /settings and run `reviews login`."
        }
        StatusCode::FORBIDDEN => {
            " — this identity is not allowed to do that on this review. Only the review owner can push revisions or decide sections; the owner or the thread's author can resolve or reopen a thread."
        }
        StatusCode::NOT_FOUND => " — the resource does not exist (check the slug?).",
        StatusCode::UNPROCESSABLE_ENTITY => " — server rejected the payload (validation error).",
        _ => "",
    },
    };
    let code_label = code.map(|c| format!(" [{c}]")).unwrap_or_default();
    Err(anyhow!(
        "{what} failed: HTTP {status}{code_label}{hint}\nbody: {body}"
    ))
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
