use anyhow::Result;
use clap::Args;
use std::env;

use crate::git;

#[derive(Args, Debug)]
pub struct DiffArgs {
    /// Git range to diff (e.g. `main..HEAD`, `HEAD~3..HEAD`). Default: HEAD~1..HEAD, then --cached.
    #[arg(long)]
    pub range: Option<String>,
}

pub fn run(args: DiffArgs) -> Result<()> {
    let cwd = env::current_dir()?;
    let cap = git::capture_diff(&cwd, args.range.as_deref())?;
    eprintln!(
        "# {} on branch {} (base {})",
        cap.source.describe(),
        cap.branch_name,
        short_sha(&cap.base_sha),
    );
    print!("{}", cap.raw_diff);
    Ok(())
}

fn short_sha(sha: &str) -> &str {
    if sha.len() >= 12 {
        &sha[..12]
    } else {
        sha
    }
}
