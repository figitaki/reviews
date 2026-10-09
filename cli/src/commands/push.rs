use anyhow::{anyhow, Context, Result};
use clap::Args;
use std::env;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use crate::api::{ApiClient, CreatePatchsetRequest, CreateReviewRequest};
use crate::config::Config;
use crate::git::{self, CapturedDiff};
use crate::packet::{self, plural, PacketCheck};

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

    /// Check the diff and packet and show what would be sent, without
    /// contacting the server. Exits with status 1 if the packet has problems.
    #[arg(long, visible_alias = "validate")]
    pub dry_run: bool,
}

pub fn run(args: PushArgs) -> Result<()> {
    let cfg = Config::load();
    // A real push needs a config before it does any work. A dry run only
    // reports on it.
    let cfg = if args.dry_run { cfg } else { Ok(cfg?) };
    let cwd = env::current_dir().context("could not read current directory")?;
    let cap = git::capture_diff(&cwd, args.range.as_deref())?;
    let check = check_packet_for_push(&cwd, &cap.branch_name, args.packet.as_ref(), &cap.raw_diff)?;

    if args.dry_run {
        let server = cfg
            .as_ref()
            .map(|cfg| cfg.default.server_url.as_str())
            .map_err(|err| format!("{err:#}"));
        print!(
            "{}",
            dry_run_report(&cwd, &args, &cap, server, check.as_ref())
        );
        return match check {
            Some(check) if !check.is_valid() => Err(anyhow!(
                "the packet has problems, so a real push would fail. Fix the problems above, then run again."
            )),
            _ => Ok(()),
        };
    }

    let cfg = cfg?;
    let packet = check.map(PacketCheck::into_packet).transpose()?;
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
            let title = review_title(&args, &cap);
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

fn review_title(args: &PushArgs, cap: &CapturedDiff) -> String {
    args.title
        .clone()
        .unwrap_or_else(|| cap.branch_name.clone())
}

/// Find the packet for this push (explicit path first, then the branch
/// default) and check it against the diff. `None` means no packet.
fn check_packet_for_push(
    cwd: &Path,
    branch_name: &str,
    explicit_path: Option<&PathBuf>,
    raw_diff: &str,
) -> Result<Option<PacketCheck>> {
    let path = match explicit_path {
        Some(path) => Some(path.clone()),
        None => packet::discover_packet(cwd, branch_name),
    };

    path.map(|path| packet::check_packet_for_diff(&path, raw_diff))
        .transpose()
}

#[cfg(test)]
fn load_packet_for_push(
    cwd: &Path,
    branch_name: &str,
    explicit_path: Option<&PathBuf>,
    raw_diff: &str,
) -> Result<Option<serde_json::Value>> {
    check_packet_for_push(cwd, branch_name, explicit_path, raw_diff)?
        .map(PacketCheck::into_packet)
        .transpose()
}

/// The text `push --dry-run` prints: where the push would go, what it would
/// send, and every packet problem.
fn dry_run_report(
    cwd: &Path,
    args: &PushArgs,
    cap: &CapturedDiff,
    server: std::result::Result<&str, String>,
    check: Option<&PacketCheck>,
) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "Dry run: nothing was sent to the server.\n");

    match server {
        Ok(url) => {
            let _ = writeln!(out, "Server:  {url}");
        }
        Err(err) => {
            let _ = writeln!(out, "Server:  not set. A real push will fail: {err}");
        }
    }

    match &args.update {
        Some(slug) => {
            let _ = writeln!(out, "Action:  add a new patchset to review {slug}");
            if args.title.is_some() || args.description.is_some() {
                let _ = writeln!(
                    out,
                    "         --title and --description are ignored with --update"
                );
            }
        }
        None => {
            let source = if args.title.is_some() {
                "from --title"
            } else {
                "from the branch name; set --title to change it"
            };
            let _ = writeln!(
                out,
                "Action:  create a new review titled \"{}\" ({source})",
                review_title(args, cap)
            );
            if let Some(description) = &args.description {
                let _ = writeln!(
                    out,
                    "         with a description of {}",
                    plural(description.chars().count(), "character")
                );
            }
        }
    }

    let files = packet::diff_files(&cap.raw_diff);
    let hunks: usize = files.iter().map(|f| f.hunks).sum();
    let _ = writeln!(
        out,
        "Diff:    {} on branch {} (base {})",
        cap.source.describe(),
        cap.branch_name,
        short_sha(&cap.base_sha)
    );
    let _ = writeln!(
        out,
        "         {}, {}, {}",
        plural(files.len(), "file"),
        plural(hunks, "hunk"),
        plural(cap.raw_diff.len(), "byte")
    );
    for file in &files {
        let _ = writeln!(
            out,
            "           {}  {}",
            file.path,
            plural(file.hunks, "hunk")
        );
    }

    let Some(check) = check else {
        let _ = writeln!(
            out,
            "Packet:  none. The review will show the diff without a packet."
        );
        let _ = writeln!(
            out,
            "\nReady to push. Run the same command without --dry-run to send it."
        );
        return out;
    };

    let display = display_path(cwd, &check.path);
    let _ = writeln!(out, "Packet:  {display}");
    if let Some(packet) = &check.packet {
        let summary = packet::summarize(packet);
        let _ = writeln!(out, "         title: {}", summary.title);
        let _ = writeln!(
            out,
            "         {}, {} across {}",
            plural(summary.sections.len(), "section"),
            plural(summary.hunk_refs, "hunk ref"),
            plural(summary.files.len(), "file")
        );
        for (idx, section) in summary.sections.iter().enumerate() {
            let _ = writeln!(
                out,
                "           {}. {}  {}",
                idx + 1,
                section.title,
                plural(section.hunk_refs, "hunk ref")
            );
        }
    }

    if check.is_valid() {
        let _ = writeln!(
            out,
            "\nPacket is valid. Run the same command without --dry-run to push it."
        );
    } else {
        let _ = writeln!(
            out,
            "\nPacket has {}:",
            plural(check.issues.len(), "problem")
        );
        for line in check.issue_lines(&display) {
            let _ = writeln!(out, "  {line}");
        }
    }
    out
}

/// The packet path relative to the working directory when it is inside it.
fn display_path(cwd: &Path, path: &Path) -> String {
    path.strip_prefix(cwd).unwrap_or(path).display().to_string()
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
        fs::write(&packet_path, "# Packet\n\nSummary\n\n## Section").unwrap();

        let packet = load_packet_for_push(dir.path(), "main", Some(&packet_path), "")
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
        fs::write(
            packet_dir.join("packet.md"),
            "# Branch Packet\n\n## Section",
        )
        .unwrap();

        let packet = load_packet_for_push(dir.path(), "carey/branch", None, "")
            .unwrap()
            .unwrap();

        assert_eq!(packet["title"], "Branch Packet");
    }

    #[test]
    fn load_packet_for_push_allows_missing_default_packet() {
        let dir = tempfile::tempdir().unwrap();
        assert!(load_packet_for_push(dir.path(), "main", None, "")
            .unwrap()
            .is_none());
    }

    #[test]
    fn load_packet_for_push_rejects_malformed_markdown() {
        let dir = tempfile::tempdir().unwrap();
        let packet_path = dir.path().join("packet.md");
        fs::write(&packet_path, "no title").unwrap();

        let err = load_packet_for_push(dir.path(), "main", Some(&packet_path), "").unwrap_err();
        assert!(format!("{err:#}").contains("# title"));
    }
}
