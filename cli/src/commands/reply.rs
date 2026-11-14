use anyhow::{anyhow, Context, Result};
use clap::Args;
use serde_json::{json, Value};

use crate::api::{ApiClient, CreateCommentRequest};
use crate::commands::parse_thread_id;
use crate::config::Config;

#[derive(Args, Debug)]
pub struct ReplyArgs {
    /// Review slug (the `:slug` in `/r/:slug`).
    pub slug: String,

    /// Thread id from `reviews threads <slug>` or `reviews show`.
    #[arg(value_parser = parse_thread_id)]
    pub thread_id: i64,

    /// Reply body. If omitted, reads from stdin.
    #[arg(long)]
    pub body: Option<String>,
}

pub fn run(args: ReplyArgs) -> Result<()> {
    let cfg = Config::load()?;
    let client = ApiClient::new(&cfg.default.server_url, &cfg.default.api_token)?;

    let body = resolve_body(args.body.as_deref())?;
    let body = body.trim();
    if body.is_empty() {
        return Err(anyhow!("reply body cannot be empty"));
    }

    // The thread already knows where it lives. Reading it back means the caller
    // only needs the id, and a wrong id fails here instead of silently opening
    // a new thread on the server.
    let review = client.show_review(&args.slug, None)?;
    let (file_path, side, line) = locate_thread(&review, args.thread_id, &args.slug)?;

    let req = CreateCommentRequest {
        file_path: &file_path,
        side: &side,
        body,
        thread_anchor: json!({
            "granularity": "line",
            "line_number_hint": line,
        }),
        thread_id: Some(args.thread_id),
    };

    let resp = client.create_comment(&args.slug, &req)?;
    println!("Replied on thread #{}: {}", resp.thread_id, resp.url);
    println!("  comment: {}", resp.comment_id);
    Ok(())
}

fn locate_thread(review: &Value, thread_id: i64, slug: &str) -> Result<(String, String, i64)> {
    let threads = review
        .get("threads")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("response does not include a threads array"))?;

    let thread = threads
        .iter()
        .find(|t| t.get("id").and_then(Value::as_i64) == Some(thread_id))
        .ok_or_else(|| {
            anyhow!("thread #{thread_id} is not in review `{slug}`. Run `reviews threads {slug}` to list ids.")
        })?;

    let file_path = thread
        .get("file_path")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("thread #{thread_id} has no file_path"))?
        .to_string();

    let side = thread
        .get("side")
        .and_then(Value::as_str)
        .unwrap_or("new")
        .to_string();

    let line = thread.get("line_hint").and_then(Value::as_i64).unwrap_or(1);

    Ok((file_path, side, line))
}

fn resolve_body(body_arg: Option<&str>) -> Result<String> {
    if let Some(s) = body_arg {
        return Ok(s.to_string());
    }
    use std::io::Read;
    let mut buf = String::new();
    std::io::stdin()
        .read_to_string(&mut buf)
        .context("could not read reply body from stdin")?;
    Ok(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn review_body() -> Value {
        json!({
            "threads": [
                {"id": 7, "file_path": "lib/cart.ex", "side": "new", "line_hint": 42},
                {"id": 9, "file_path": "README.md", "side": "old"}
            ]
        })
    }

    #[test]
    fn locates_thread_by_id() {
        let (path, side, line) = locate_thread(&review_body(), 7, "abc").unwrap();
        assert_eq!(path, "lib/cart.ex");
        assert_eq!(side, "new");
        assert_eq!(line, 42);
    }

    #[test]
    fn defaults_side_and_line_when_absent() {
        let (path, side, line) = locate_thread(&review_body(), 9, "abc").unwrap();
        assert_eq!(path, "README.md");
        assert_eq!(side, "old");
        assert_eq!(line, 1);
    }

    #[test]
    fn unknown_thread_id_points_at_the_listing_command() {
        let err = locate_thread(&review_body(), 404, "abc").unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("not in review `abc`"), "msg = {msg}");
        assert!(msg.contains("reviews threads abc"), "msg = {msg}");
    }
}
