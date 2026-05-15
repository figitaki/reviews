use anyhow::{Context, Result};
use clap::Args;
use std::env;
use std::path::PathBuf;

use crate::api::{ApiClient, CreatePatchsetRequest, CreateReviewRequest};
use crate::config::Config;
use crate::git;
use crate::packet;

#[derive(Args, Debug)]
pub struct PushArgs {
    /// Git range to diff (e.g. `main..HEAD`). Default: HEAD~1..HEAD, then --cached.
    #[arg(long)]
    pub range: Option<String>,

    /// Title for a new review. Defaults to the branch name. Ignored with --update.
    #[arg(long)]
    pub title: Option<String>,

    /// Optional markdown description for a new review. Ignored with --update.
    #[arg(long)]
    pub description: Option<String>,

    /// Packet file to upload (.md or .json). Defaults to .reviews/<branch>/packet.md, then packet.json.
    #[arg(long)]
    pub packet: Option<PathBuf>,

    /// Append a new patchset to an existing review by slug.
    #[arg(long, value_name = "SLUG")]
    pub update: Option<String>,
}

pub fn run(args: PushArgs) -> Result<()> {
    let cfg = Config::load()?;
    let cwd = env::current_dir().context("could not read current directory")?;
    let cap = git::capture_diff(&cwd, args.range.as_deref())?;
    let packet = load_packet_for_push(&cwd, &cap.branch_name, args.packet.as_ref())?;

    let client = ApiClient::new(&cfg.default.server_url, &cfg.default.api_token)?;

    eprintln!(
        "Captured diff: {} on branch {} (base {}).",
        cap.source.describe(),
        cap.branch_name,
        short_sha(&cap.base_sha),
    );

    match args.update {
        Some(slug) => {
            let req = CreatePatchsetRequest {
                base_sha: &cap.base_sha,
                branch_name: &cap.branch_name,
                raw_diff: &cap.raw_diff,
                packet: packet.as_ref(),
            };
            let resp = client.create_patchset(&slug, &req)?;
            println!("Patchset {} added to {}", resp.patchset_number, resp.url);
        }
        None => {
            let title = args
                .title
                .clone()
                .unwrap_or_else(|| cap.branch_name.clone());
            let description = args.description.clone().unwrap_or_default();
            let req = CreateReviewRequest {
                title: &title,
                description: &description,
                base_sha: &cap.base_sha,
                branch_name: &cap.branch_name,
                raw_diff: &cap.raw_diff,
                packet: packet.as_ref(),
            };
            let resp = client.create_review(&req)?;
            println!("Review created: {}", resp.url);
            println!("  slug: {}  patchset: {}", resp.slug, resp.patchset_number);
        }
    }
    Ok(())
}

fn load_packet_for_push(
    cwd: &std::path::Path,
    branch_name: &str,
    explicit_path: Option<&PathBuf>,
) -> Result<Option<serde_json::Value>> {
    let path = match explicit_path {
        Some(path) => Some(path.clone()),
        None => packet::discover_packet(cwd, branch_name),
    };

    match path {
        Some(path) => Ok(Some(packet::load_packet(&path)?)),
        None => Ok(None),
    }
}

fn short_sha(sha: &str) -> &str {
    if sha.len() >= 12 {
        &sha[..12]
    } else {
        sha
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn load_packet_for_push_uses_explicit_markdown() {
        let dir = tempfile::tempdir().unwrap();
        let packet_path = dir.path().join("packet.md");
        fs::write(&packet_path, "# Packet\n\nSummary").unwrap();

        let packet = load_packet_for_push(dir.path(), "main", Some(&packet_path))
            .unwrap()
            .unwrap();

        assert_eq!(packet["title"], "Packet");
        assert_eq!(packet["summary"], "Summary");
    }

    #[test]
    fn load_packet_for_push_discovers_branch_packet() {
        let dir = tempfile::tempdir().unwrap();
        let packet_dir = dir.path().join(".reviews").join("carey__branch");
        fs::create_dir_all(&packet_dir).unwrap();
        fs::write(packet_dir.join("packet.md"), "# Branch Packet").unwrap();

        let packet = load_packet_for_push(dir.path(), "carey/branch", None)
            .unwrap()
            .unwrap();

        assert_eq!(packet["title"], "Branch Packet");
    }

    #[test]
    fn load_packet_for_push_allows_missing_default_packet() {
        let dir = tempfile::tempdir().unwrap();
        assert!(load_packet_for_push(dir.path(), "main", None)
            .unwrap()
            .is_none());
    }

    #[test]
    fn load_packet_for_push_rejects_malformed_markdown() {
        let dir = tempfile::tempdir().unwrap();
        let packet_path = dir.path().join("packet.md");
        fs::write(&packet_path, "no title").unwrap();

        let err = load_packet_for_push(dir.path(), "main", Some(&packet_path)).unwrap_err();
        assert!(format!("{err:#}").contains("# title"));
    }
}
