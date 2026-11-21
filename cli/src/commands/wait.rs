use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use clap::Args;
use serde_json::Value;

use crate::api::{ApiError, WaitCommentsResponse};
use crate::auth;
use crate::config::Config;

/// Exit status when `--timeout` passes, as `timeout(1)` uses.
pub const TIMED_OUT_EXIT_CODE: i32 = 124;

/// Seconds the server holds one request. It caps this at 30; staying under it
/// leaves room for proxies with a 30-second idle limit.
const POLL_SECONDS: u64 = 25;

/// The server's limit on reviews per wait.
const MAX_REVIEWS: usize = 20;

/// Without `--follow` and `--timeout`, give up after this many seconds.
const DEFAULT_TIMEOUT_SECONDS: u64 = 600;

/// Consecutive failed polls (network errors, HTTP 429 or 5xx) a one-shot wait
/// retries before giving up; the delay doubles from one second.
const MAX_RETRIES: u32 = 5;

/// The longest delay between retries, so a follower notices a recovered server
/// within a minute.
const MAX_RETRY_DELAY_SECONDS: u64 = 60;

#[derive(Args, Debug)]
pub struct WaitArgs {
    /// Review slugs (the `:slug` in `/r/:slug`), at most 20. One cursor
    /// covers all of them.
    #[arg(required = true, num_args = 1..)]
    pub slugs: Vec<String>,

    /// Keep waiting after comments arrive, printing each as it comes. Runs
    /// until an error or `--timeout`.
    #[arg(long)]
    pub follow: bool,

    /// Cursor from an earlier line (its `cursor` field). Comments with a
    /// higher id are printed at once. Without it or `--cursor-file`, waits
    /// for comments published after the command starts.
    #[arg(long)]
    pub since: Option<i64>,

    /// Read the starting cursor from this file if it exists, and write the
    /// cursor of the last printed comment to it, so a restart resumes there.
    #[arg(long)]
    pub cursor_file: Option<PathBuf>,

    /// Stop after this many seconds and exit with status 124. Defaults to 600
    /// without `--follow`; with `--follow` there is no limit.
    #[arg(long)]
    pub timeout: Option<u64>,
}

/// Whether `run` printed new comments or the timeout passed first.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Comments,
    TimedOut,
}

pub fn run(args: WaitArgs) -> Result<Outcome> {
    if args.slugs.len() > MAX_REVIEWS {
        return Err(anyhow!("wait on at most {MAX_REVIEWS} reviews at once"));
    }
    let cfg = Config::load()?;
    let saved = match &args.cursor_file {
        Some(path) => read_cursor(path)?,
        None => None,
    };
    let since = args.since.or(saved);
    let bound = match (args.timeout, args.follow) {
        (Some(secs), _) => Some(secs),
        (None, false) => Some(DEFAULT_TIMEOUT_SECONDS),
        (None, true) => None,
    };
    let deadline = bound.map(|secs| Instant::now() + Duration::from_secs(secs));
    let result = follow_loop(&cfg, &args, since, saved, deadline);
    if let (true, Err(err)) = (args.follow, &result) {
        // A reader tailing the output learns that the follower stopped.
        println!("{}", serde_json::json!({ "error": format!("{err:#}") }));
    }
    result
}

fn follow_loop(
    cfg: &Config,
    args: &WaitArgs,
    mut since: Option<i64>,
    mut saved: Option<i64>,
    deadline: Option<Instant>,
) -> Result<Outcome> {
    // A one-shot wait gives up after a few failures; a follower runs
    // unattended, so it keeps retrying until `--timeout`.
    let max_retries = if args.follow { None } else { Some(MAX_RETRIES) };
    loop {
        let poll = deadline.map_or(POLL_SECONDS, |d| seconds_left(d).min(POLL_SECONDS));
        let resp = poll_with_retries(cfg, &args.slugs, since, poll, deadline, max_retries)?;

        if !resp.comments.is_empty() {
            print_lines(&resp.comments)?;
        }
        // Saved after every poll that moves it, including an empty first poll,
        // so a restart resumes from here rather than from "now".
        if let (Some(path), true) = (&args.cursor_file, saved != Some(resp.cursor)) {
            write_cursor(path, resp.cursor)?;
            saved = Some(resp.cursor);
        }
        since = Some(resp.cursor);

        if !resp.comments.is_empty() && !args.follow {
            return Ok(Outcome::Comments);
        }
        // Under a second left would poll with `timeout=0` in a tight loop.
        if deadline.is_some_and(|d| seconds_left(d) == 0) {
            return Ok(Outcome::TimedOut);
        }
    }
}

fn seconds_left(deadline: Instant) -> u64 {
    deadline.saturating_duration_since(Instant::now()).as_secs()
}

fn poll_with_retries(
    cfg: &Config,
    slugs: &[String],
    since: Option<i64>,
    poll: u64,
    deadline: Option<Instant>,
    max_retries: Option<u32>,
) -> Result<WaitCommentsResponse> {
    let mut failures: u32 = 0;
    loop {
        // Each poll asks for a fresh token so a long wait outlives its expiry.
        let result = auth::client(cfg).and_then(|c| c.wait_comments(slugs, since, poll));
        let err = match result {
            Ok(resp) => return Ok(resp),
            Err(err) => err,
        };
        if !retryable(&err) || max_retries.is_some_and(|max| failures >= max) {
            return Err(err);
        }
        let delay = retry_delay(failures);
        if deadline.is_some_and(|d| d.saturating_duration_since(Instant::now()) < delay) {
            return Err(err);
        }
        eprintln!("warning: {err:#}\nretrying in {}s", delay.as_secs());
        std::thread::sleep(delay);
        failures = failures.saturating_add(1);
    }
}

/// One second, doubling per failure, at most `MAX_RETRY_DELAY_SECONDS`.
fn retry_delay(failures: u32) -> Duration {
    Duration::from_secs((1u64 << failures.min(6)).min(MAX_RETRY_DELAY_SECONDS))
}

/// Network failures and server-side errors; a 4xx answer will not change.
fn retryable(err: &anyhow::Error) -> bool {
    match err.downcast_ref::<ApiError>() {
        Some(api) => api.status == 429 || api.status >= 500,
        None => err.chain().any(|cause| cause.is::<reqwest::Error>()),
    }
}

/// One compact JSON object per comment per line, flushed so a reader tailing
/// the output sees each comment as soon as it arrives.
fn print_lines(comments: &[Value]) -> Result<()> {
    let mut out = std::io::stdout().lock();
    for comment in comments {
        let mut line = comment.clone();
        if let Some(obj) = line.as_object_mut() {
            let id = obj.get("comment_id").cloned().unwrap_or(Value::Null);
            obj.insert("cursor".to_string(), id);
        }
        writeln!(out, "{line}").context("could not write to stdout")?;
    }
    out.flush().context("could not write to stdout")
}

fn read_cursor(path: &Path) -> Result<Option<i64>> {
    match fs::read_to_string(path) {
        Ok(text) => {
            text.trim().parse::<i64>().map(Some).with_context(|| {
                format!("{} does not hold a cursor (a whole number)", path.display())
            })
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err).with_context(|| format!("could not read {}", path.display())),
    }
}

/// Writes through a new, uniquely named temporary file in the same directory
/// and a rename, so a reader never sees a partly written cursor and a planted
/// file or symlink is never written through.
fn write_cursor(path: &Path, cursor: i64) -> Result<()> {
    let dir = match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => Path::new("."),
    };
    let mut tmp = tempfile::NamedTempFile::new_in(dir)
        .with_context(|| format!("could not create a temporary file in {}", dir.display()))?;
    writeln!(tmp, "{cursor}").context("could not write the cursor")?;
    tmp.persist(path)
        .with_context(|| format!("could not write {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_file_round_trips_and_missing_means_none() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cursor");
        assert_eq!(read_cursor(&path).unwrap(), None);
        write_cursor(&path, 42).unwrap();
        assert_eq!(read_cursor(&path).unwrap(), Some(42));
        fs::write(&path, "nope").unwrap();
        assert!(read_cursor(&path).is_err());
    }

    #[test]
    fn cursor_writes_never_follow_a_planted_temp_file() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target");
        fs::write(&target, "keep\n").unwrap();
        let path = dir.path().join("cursor.a");
        std::os::unix::fs::symlink(&target, dir.path().join("cursor.tmp")).unwrap();

        write_cursor(&path, 7).unwrap();
        write_cursor(&dir.path().join("cursor.b"), 8).unwrap();

        assert_eq!(fs::read_to_string(&target).unwrap(), "keep\n");
        assert_eq!(read_cursor(&path).unwrap(), Some(7));
        assert_eq!(read_cursor(&dir.path().join("cursor.b")).unwrap(), Some(8));
    }

    #[test]
    fn retry_delay_doubles_and_caps_at_a_minute() {
        let secs: Vec<u64> = (0..9).map(|n| retry_delay(n).as_secs()).collect();
        assert_eq!(secs, vec![1, 2, 4, 8, 16, 32, 60, 60, 60]);
    }

    #[test]
    fn only_server_and_network_errors_are_retried() {
        let api = |status| {
            anyhow::Error::new(ApiError {
                status,
                code: None,
                message: String::new(),
            })
        };
        assert!(retryable(&api(503)));
        assert!(retryable(&api(429)));
        assert!(!retryable(&api(404)));
        assert!(!retryable(&anyhow!("bad config")));
    }
}
