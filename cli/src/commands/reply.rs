use anyhow::{anyhow, Context, Result};
use clap::Args;

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

    let req = CreateCommentRequest {
        file_path: None,
        side: None,
        body,
        thread_anchor: None,
        revision: None,
        thread_id: Some(args.thread_id),
    };

    let resp = client.create_comment(&args.slug, &req)?;
    println!("Replied on thread #{}: {}", resp.thread_id, resp.url);
    println!("  comment: {}", resp.comment_id);
    Ok(())
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
