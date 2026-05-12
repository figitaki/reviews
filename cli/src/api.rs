//! Thin reqwest blocking wrapper around the Phoenix REST API.
//!
//! Endpoints (see docs/CONTRACTS.md):
//!   GET  /api/v1/me
//!   POST /api/v1/reviews
//!   POST /api/v1/reviews/:slug/patchsets

use anyhow::{anyhow, Context, Result};
use reqwest::blocking::{Client, Response};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use std::time::Duration;

pub struct ApiClient {
    base_url: String,
    token: String,
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

impl ApiClient {
    pub fn new(base_url: impl Into<String>, token: impl Into<String>) -> Result<Self> {
        let http = Client::builder()
            .timeout(Duration::from_secs(60))
            .user_agent(concat!("reviews-cli/", env!("CARGO_PKG_VERSION")))
            .build()
            .context("could not build HTTP client")?;
        Ok(ApiClient {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            token: token.into(),
            http,
        })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base_url, path)
    }

    pub fn me(&self) -> Result<Me> {
        let resp = self
            .http
            .get(self.url("/api/v1/me"))
            .bearer_auth(&self.token)
            .send()
            .context("could not reach server for GET /api/v1/me")?;
        let resp = check_status(resp, "GET /api/v1/me")?;
        resp.json::<Me>()
            .context("could not parse /api/v1/me response as JSON")
    }

    pub fn create_review(&self, req: &CreateReviewRequest<'_>) -> Result<CreateReviewResponse> {
        let resp = self
            .http
            .post(self.url("/api/v1/reviews"))
            .bearer_auth(&self.token)
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
        let resp = self
            .http
            .post(self.url(&path))
            .bearer_auth(&self.token)
            .json(req)
            .send()
            .with_context(|| format!("could not reach server for POST {path}"))?;
        let resp = check_status(resp, &format!("POST {path}"))?;
        resp.json::<CreatePatchsetResponse>()
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
}
