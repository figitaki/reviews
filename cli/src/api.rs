//! Thin reqwest blocking wrapper around the Phoenix REST API.
//!
//! Endpoints (see docs/CONTRACTS.md):
//!   GET  /api/v1/me
//!   POST /api/v1/reviews
//!   POST /api/v1/reviews/:slug/patchsets
//!   GET  /api/v1/reviews/:slug

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
    pub email: String,
}

#[derive(Debug, Serialize)]
pub struct CreateReviewRequest<'a> {
    pub title: &'a str,
    pub description: &'a str,
    pub base_sha: &'a str,
    pub branch_name: &'a str,
    pub raw_diff: &'a str,
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
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreatePatchsetResponse {
    pub patchset_number: i64,
    pub url: String,
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
    Err(anyhow!(
        "{what} failed: HTTP {status}{hint}\nbody: {body}"
    ))
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
            .with_body(r#"{"username":"careyjanecka","email":"carey@example.com"}"#)
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let me = client.me().unwrap();
        assert_eq!(me.username, "careyjanecka");
        assert_eq!(me.email, "carey@example.com");
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
