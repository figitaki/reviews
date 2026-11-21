use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use clap::Args;

use crate::api::WaitCommentsResponse;
use crate::auth;
use crate::config::Config;

/// Exit status when no comment arrived before `--timeout`, as `timeout(1)` uses.
pub const TIMED_OUT_EXIT_CODE: i32 = 124;

/// Seconds the server holds one request. It caps this at 30; staying under it
/// leaves room for proxies with a 30-second idle limit.
const POLL_SECONDS: u64 = 25;

#[derive(Args, Debug)]
pub struct WaitArgs {
    /// Review slug (the `:slug` in `/r/:slug`).
    pub slug: String,

    /// Cursor from a previous `reviews wait` (its `cursor` field). Comments
    /// with a higher id are returned at once. Without it, waits for comments
    /// published after the command starts.
    #[arg(long)]
    pub since: Option<i64>,

    /// Give up after this many seconds and exit with status 124.
    #[arg(long, default_value_t = 600)]
    pub timeout: u64,
}

/// Whether `run` printed new comments or gave up.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Comments,
    TimedOut,
}

pub fn run(args: WaitArgs) -> Result<Outcome> {
    let cfg = Config::load()?;
    let deadline = Instant::now() + Duration::from_secs(args.timeout);
    let mut since = args.since;

    loop {
        let remaining = deadline.saturating_duration_since(Instant::now()).as_secs();
        // Each poll asks for a fresh token so a long wait outlives its expiry.
        let client = auth::client(&cfg)?;
        let resp = client.wait_comments(&args.slug, since, remaining.min(POLL_SECONDS))?;
        since = Some(resp.cursor);

        if !resp.comments.is_empty() {
            print_response(&resp)?;
            return Ok(Outcome::Comments);
        }
        // Under a second left would poll with `timeout=0` in a tight loop.
        if deadline.saturating_duration_since(Instant::now()) < Duration::from_secs(1) {
            print_response(&resp)?;
            return Ok(Outcome::TimedOut);
        }
    }
}

fn print_response(resp: &WaitCommentsResponse) -> Result<()> {
    let json = serde_json::to_string_pretty(resp).context("could not encode the comments")?;
    println!("{json}");
    Ok(())
}
