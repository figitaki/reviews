use anyhow::{anyhow, Context, Result};
use clap::Args;
use serde_json::json;

use crate::api::{ApiClient, CreateCommentRequest};
use crate::config::Config;

#[derive(Args, Debug)]
pub struct CommentArgs {
    /// Review slug (the `:slug` in `/r/:slug`).
    pub slug: String,

    /// Location of the comment, formatted as `<file>:<line>`.
    pub location: String,

    /// Comment body. If omitted, reads from stdin.
    #[arg(long)]
    pub body: Option<String>,

    /// Pin the anchor to a substring on that line. When omitted, anchors
    /// the comment to the whole line (granularity "line").
    #[arg(long, value_name = "SUBSTRING")]
    pub token: Option<String>,

    /// Which side of the diff to anchor to. Defaults to "new".
    #[arg(long, default_value = "new", value_parser = ["new", "old"])]
    pub side: String,
}

pub fn run(args: CommentArgs) -> Result<()> {
    let cfg = Config::load()?;
    let client = ApiClient::new(&cfg.default.server_url, &cfg.default.api_token)?;

    let (file_path, line_number) = parse_location(&args.location)?;
    let body = resolve_body(args.body.as_deref())?;
    let body = body.trim();
    if body.is_empty() {
        return Err(anyhow!("comment body cannot be empty"));
    }

    let anchor = build_anchor(line_number, args.token.as_deref());
    let req = CreateCommentRequest {
        file_path: &file_path,
        side: &args.side,
        body,
        thread_anchor: anchor,
    };

    let resp = client.create_comment(&args.slug, &req)?;
    println!("Comment published: {}", resp.url);
    println!("  thread: {}  comment: {}", resp.thread_id, resp.comment_id);
    Ok(())
}

fn parse_location(loc: &str) -> Result<(String, i64)> {
    let (file, line) = loc
        .rsplit_once(':')
        .ok_or_else(|| anyhow!("location must look like <file>:<line>, got `{loc}`"))?;

    if file.is_empty() {
        return Err(anyhow!("location is missing a file path"));
    }

    let line: i64 = line
        .parse()
        .with_context(|| format!("line number `{line}` is not a positive integer"))?;
    if line <= 0 {
        return Err(anyhow!("line number must be >= 1"));
    }
    Ok((file.to_string(), line))
}

fn resolve_body(body_arg: Option<&str>) -> Result<String> {
    if let Some(s) = body_arg {
        return Ok(s.to_string());
    }
    use std::io::Read;
    let mut buf = String::new();
    std::io::stdin()
        .read_to_string(&mut buf)
        .context("could not read comment body from stdin")?;
    Ok(buf)
}

fn build_anchor(line_number: i64, token: Option<&str>) -> serde_json::Value {
    match token {
        Some(t) => json!({
            "granularity": "token_range",
            "line_number_hint": line_number,
            "selection_text": t,
        }),
        None => json!({
            "granularity": "line",
            "line_number_hint": line_number,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_location_splits_file_and_line() {
        assert_eq!(
            parse_location("lib/foo.ex:42").unwrap(),
            ("lib/foo.ex".to_string(), 42)
        );
    }

    #[test]
    fn parse_location_handles_colon_in_filename() {
        assert_eq!(parse_location("a:b:7").unwrap(), ("a:b".to_string(), 7));
    }

    #[test]
    fn parse_location_rejects_missing_line() {
        assert!(parse_location("lib/foo.ex").is_err());
        assert!(parse_location("lib/foo.ex:").is_err());
        assert!(parse_location("lib/foo.ex:0").is_err());
        assert!(parse_location("lib/foo.ex:-1").is_err());
        assert!(parse_location("lib/foo.ex:abc").is_err());
    }

    #[test]
    fn build_anchor_line_when_no_token() {
        let a = build_anchor(7, None);
        assert_eq!(a["granularity"], "line");
        assert_eq!(a["line_number_hint"], 7);
        assert!(a.get("selection_text").is_none());
    }

    #[test]
    fn build_anchor_token_range_when_token() {
        let a = build_anchor(7, Some("GITHUB_CLIENT_ID"));
        assert_eq!(a["granularity"], "token_range");
        assert_eq!(a["line_number_hint"], 7);
        assert_eq!(a["selection_text"], "GITHUB_CLIENT_ID");
    }
}
