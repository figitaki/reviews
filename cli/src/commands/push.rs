use anyhow::{Context, Result};
use clap::Args;
use std::env;

use crate::api::{ApiClient, CreatePatchsetRequest, CreateReviewRequest};
use crate::config::Config;
use crate::git;

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

    /// Append a new patchset to an existing review by slug.
    #[arg(long, value_name = "SLUG")]
    pub update: Option<String>,
}

pub fn run(args: PushArgs) -> Result<()> {
    let cfg = Config::load()?;
    let cwd = env::current_dir().context("could not read current directory")?;
    let cap = git::capture_diff(&cwd, args.range.as_deref())?;

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
            };
            let resp = client.create_patchset(&slug, &req)?;
            println!(
                "Patchset {} added to {}",
                resp.patchset_number, resp.url
            );
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
            };
            let resp = client.create_review(&req)?;
            println!("Review created: {}", resp.url);
            println!("  slug: {}  patchset: {}", resp.slug, resp.patchset_number);
        }
    }
    Ok(())
}

fn short_sha(sha: &str) -> &str {
    if sha.len() >= 12 {
        &sha[..12]
    } else {
        sha
    }
}
