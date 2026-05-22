use anyhow::{anyhow, Result};
use clap::Args;
use serde_json::Value;

use crate::api::ApiClient;
use crate::config::Config;

const DEFAULT_SERVER: &str = "https://reviews.figitaki.dev";

#[derive(Args, Debug)]
pub struct ThreadsArgs {
    /// Review slug (the `:slug` in `/r/:slug`).
    pub slug: String,

    /// Override server URL. Defaults to the configured server, or
    /// https://reviews.figitaki.dev if not logged in.
    #[arg(long)]
    pub server: Option<String>,
}

pub fn run(args: ThreadsArgs) -> Result<()> {
    let (server_url, token) = resolve_server_and_token(args.server.as_deref())?;
    let client = match token {
        Some(t) => ApiClient::new(server_url, t)?,
        None => ApiClient::anonymous(server_url)?,
    };
    let body = client.show_review(&args.slug, None)?;
    print!("{}", render_threads(&body)?);
    Ok(())
}

fn resolve_server_and_token(server_override: Option<&str>) -> Result<(String, Option<String>)> {
    if let Some(s) = server_override {
        return Ok((s.to_string(), None));
    }
    match Config::load() {
        Ok(cfg) => Ok((cfg.default.server_url, Some(cfg.default.api_token))),
        Err(_) => Ok((DEFAULT_SERVER.to_string(), None)),
    }
}

fn render_threads(body: &Value) -> Result<String> {
    let threads = body
        .get("threads")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("response does not include a threads array"))?;

    if threads.is_empty() {
        return Ok("No threads.\n".to_string());
    }

    let mut out = String::new();
    for t in threads {
        let id = t.get("id").and_then(Value::as_i64).unwrap_or(0);
        let status = t.get("status").and_then(Value::as_str).unwrap_or("open");
        let path = t.get("file_path").and_then(Value::as_str).unwrap_or("?");
        let line = t.get("line_hint").and_then(Value::as_i64);
        let author = t
            .get("author")
            .and_then(Value::as_str)
            .unwrap_or("anonymous");
        let first = t
            .get("comments")
            .and_then(Value::as_array)
            .and_then(|comments| comments.first())
            .and_then(|comment| comment.get("body"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .lines()
            .next()
            .unwrap_or("");
        let location = match line {
            Some(n) => format!("{path}:{n}"),
            None => path.to_string(),
        };
        out.push_str(&format!("#{id} [{status}] {location} @{author}"));
        if !first.is_empty() {
            out.push_str(&format!(" — {first}"));
        }
        out.push('\n');
    }

    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn render_threads_lists_ids_status_and_first_comment() {
        let body = json!({
            "threads": [{
                "id": 7,
                "status": "open",
                "file_path": "foo",
                "line_hint": 3,
                "author": "carey",
                "comments": [{"body": "nit: rename?\nmore"}]
            }]
        });

        assert_eq!(
            render_threads(&body).unwrap(),
            "#7 [open] foo:3 @carey — nit: rename?\n"
        );
    }

    #[test]
    fn render_threads_handles_empty_threads() {
        let body = json!({"threads": []});
        assert_eq!(render_threads(&body).unwrap(), "No threads.\n");
    }
}
