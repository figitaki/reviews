use anyhow::{anyhow, bail, Context, Result};
use clap::Args;
use std::env;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use crate::api::{
    api_error_code, ApiClient, Capabilities, CodeSnapshotResult, CreatePatchsetRequest,
    CreateReviewRequest, ReserveSnapshotRequest,
};
use crate::auth;
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
    /// contacting the server. Exits with status 1 if the packet or the push
    /// has problems.
    #[arg(long, visible_alias = "validate")]
    pub dry_run: bool,

    /// Include full text context for changed files in Reviews (up to 4 MiB).
    /// Signed-in readers can expand unchanged lines. Independent of code.storage.
    #[arg(long)]
    pub include_context: bool,

    /// Skip uploading repository code to code.storage for this push.
    #[arg(long)]
    pub no_code_storage: bool,
}

/// What to do about code upload for this push, from server capabilities and
/// flags. Pure so the policy matrix is unit-testable.
#[derive(Debug, Clone, PartialEq, Eq)]
enum CodePolicy {
    /// Server has no code storage (old server, or disabled): push diff only.
    Disabled,
    /// Upload; on failure warn and fall back to diff-only.
    Optional,
    /// Upload; on failure abort before creating anything.
    Required,
}

fn code_policy(
    caps: Option<&Capabilities>,
    no_code_storage: bool,
    object_format: &str,
) -> Result<CodePolicy> {
    match caps.map(|c| &c.code_storage) {
        None => Ok(CodePolicy::Disabled),
        Some(cs) if !cs.enabled => Ok(CodePolicy::Disabled),
        Some(cs) if cs.required && no_code_storage => {
            bail!("this server requires code storage; --no-code-storage cannot be used here")
        }
        Some(_) if no_code_storage => Ok(CodePolicy::Disabled),
        Some(cs)
            if !cs
                .supported_object_formats
                .iter()
                .any(|f| f == object_format) =>
        {
            if cs.required {
                bail!(
                    "this server requires code storage but does not support this repository's \
                     object format ({object_format})"
                );
            }
            eprintln!(
                "warning: server does not support this repository's object format \
                 ({object_format}); pushing diff only"
            );
            Ok(CodePolicy::Disabled)
        }
        Some(cs) if cs.required => Ok(CodePolicy::Required),
        Some(_) => Ok(CodePolicy::Optional),
    }
}

pub fn run(args: PushArgs) -> Result<()> {
    let cfg = Config::load();
    // A real push needs a config before it does any work. A dry run only
    // reports on it.
    let cfg = if args.dry_run { cfg } else { Ok(cfg?) };
    let cwd = env::current_dir().context("could not read current directory")?;
    let cap = git::capture_diff(&cwd, args.range.as_deref())?;
    let context_diff = args
        .include_context
        .then(|| git::capture_context_diff(&cwd, &cap))
        .transpose()?;
    let check = check_packet_for_push(&cwd, &cap.branch_name, args.packet.as_ref(), &cap.raw_diff)?;
    let problems = request_problems(&args, &cap);

    if args.dry_run {
        let server = cfg
            .as_ref()
            .map(|cfg| cfg.default.server_url.as_str())
            .map_err(|err| format!("{err:#}"));
        print!(
            "{}",
            dry_run_report(&cwd, &args, &cap, server, check.as_ref(), &problems)
        );
        let packet_ok = check.as_ref().is_none_or(PacketCheck::is_valid);
        return if packet_ok && problems.is_empty() {
            Ok(())
        } else {
            Err(anyhow!(
                "a real push would fail. Fix the problems above, then run again."
            ))
        };
    }

    let cfg = cfg?;
    if !problems.is_empty() {
        return Err(anyhow!("{}", problems.join("\n")));
    }
    let packet = check.map(PacketCheck::into_packet).transpose()?;
    let client = auth::client(&cfg)?;

    eprintln!(
        "Captured diff: {} on branch {} (base {}).",
        cap.source.describe(),
        cap.branch_name,
        short_sha(&cap.base_sha),
    );

    // A failed capabilities check must not block a diff-only push. The
    // server still accepts pushes without a snapshot.
    let caps = match client.capabilities() {
        Ok(caps) => caps,
        Err(err) => {
            eprintln!("warning: could not check code storage support ({err:#}); pushing diff only");
            None
        }
    };
    let policy = code_policy(caps.as_ref(), args.no_code_storage, &cap.object_format)?;
    let snapshot_id = match policy {
        CodePolicy::Disabled => None,
        CodePolicy::Optional => {
            match upload_snapshot(&client, &cwd, &cap, args.update.as_deref()) {
                Ok(id) => Some(id),
                Err(err) => {
                    eprintln!("warning: code snapshot upload failed ({err:#}); pushing diff only");
                    None
                }
            }
        }
        CodePolicy::Required => Some(
            upload_snapshot(&client, &cwd, &cap, args.update.as_deref())
                .context("this server requires code storage, so the push was aborted")?,
        ),
    };

    match args.update {
        Some(slug) => {
            let req = CreatePatchsetRequest {
                base_sha: &cap.base_sha,
                branch_name: &cap.branch_name,
                raw_diff: &cap.raw_diff,
                context_diff: context_diff.as_deref(),
                packet: packet.as_ref(),
                code_snapshot_id: snapshot_id.as_deref(),
            };
            let resp = client.create_patchset(&slug, &req)?;
            warn_if_skipped(resp.code_snapshot.as_ref());
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
                context_diff: context_diff.as_deref(),
                packet: packet.as_ref(),
                code_snapshot_id: snapshot_id.as_deref(),
            };
            let resp = client.create_review(&req)?;
            warn_if_skipped(resp.code_snapshot.as_ref());
            println!("Review created: {}", resp.url);
            println!("  slug: {}  patchset: {}", resp.slug, resp.patchset_number);
        }
    }
    Ok(())
}

/// Reserve, upload, and verify a code snapshot; returns its id for the push
/// payload. Every step is fail-fast — the caller decides (per policy)
/// whether a failure aborts the push or degrades to diff-only.
fn upload_snapshot(
    client: &ApiClient,
    repo: &Path,
    cap: &git::CapturedDiff,
    review_slug: Option<&str>,
) -> Result<String> {
    let commits = git::create_snapshot_commits(repo, cap)?;

    let reservation = client
        .reserve_snapshot(&ReserveSnapshotRequest {
            review_slug,
            object_format: &cap.object_format,
            base_oid: &commits.base_oid,
            head_oid: &commits.head_oid,
            head_kind: commits.head_kind,
        })
        .map_err(annotate_snapshot_error)?;

    eprintln!("Uploading code snapshot ({})...", commits.head_kind);

    git::push_snapshot_refs(
        repo,
        &reservation.upload.remote_url,
        &reservation.upload.token,
        &commits.base_oid,
        &reservation.refs.base,
        &commits.head_oid,
        &reservation.refs.head,
    )?;

    let completed = client
        .complete_snapshot(&reservation.id)
        .map_err(annotate_snapshot_error)?;
    if completed.status != "ready" {
        bail!(
            "server did not verify the uploaded snapshot (status: {})",
            completed.status
        );
    }

    Ok(reservation.id)
}

/// Fold the server's stable error codes into the four user-distinguishable
/// snapshot outcomes from the spec.
fn annotate_snapshot_error(err: anyhow::Error) -> anyhow::Error {
    let note = match api_error_code(&err) {
        Some("code_storage_disabled") => "the server disabled code storage mid-push",
        Some("unsupported_object_format") => "this repository's object format is not supported",
        Some("upload_expired") => "the reservation expired before the upload was claimed",
        Some("ref_mismatch") => "the uploaded refs did not match the reserved commits",
        _ => return err,
    };
    err.context(note.to_string())
}

fn warn_if_skipped(result: Option<&CodeSnapshotResult>) {
    if let Some(cs) = result {
        if cs.status == "skipped" {
            eprintln!(
                "warning: server did not attach the code snapshot ({})",
                cs.code.as_deref().unwrap_or("unknown")
            );
        }
    }
}

fn review_title(args: &PushArgs, cap: &CapturedDiff) -> String {
    args.title
        .clone()
        .unwrap_or_else(|| cap.branch_name.clone())
}

/// Problems with the request itself that the server would reject: an empty
/// review title (the server requires one) or an empty `--update` slug.
fn request_problems(args: &PushArgs, cap: &CapturedDiff) -> Vec<String> {
    match &args.update {
        Some(slug) if slug.trim().is_empty() => {
            vec!["--update needs a review slug, such as `--update k7m2qz`.".to_string()]
        }
        Some(_) => Vec::new(),
        None if review_title(args, cap).trim().is_empty() => {
            vec!["the review title is empty. Pass --title with some text.".to_string()]
        }
        None => Vec::new(),
    }
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
    problems: &[String],
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
        if !write_problems(&mut out, problems) {
            let _ = writeln!(
                out,
                "\nReady to push. Run the same command without --dry-run to send it."
            );
        }
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

    if !check.notes.is_empty() {
        let _ = writeln!(
            out,
            "\nPacket has {}. Notes do not stop a push:",
            plural(check.notes.len(), "note")
        );
        for line in check.note_lines(&display) {
            let _ = writeln!(out, "  {line}");
        }
    }

    let has_problems = write_problems(&mut out, problems);
    if check.is_valid() {
        let next = if has_problems {
            "Fix the push problems above before you push."
        } else {
            "Run the same command without --dry-run to push it."
        };
        let _ = writeln!(out, "\nPacket is valid. {next}");
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

/// Write the push problems, if any. Returns whether there were any.
fn write_problems(out: &mut String, problems: &[String]) -> bool {
    if problems.is_empty() {
        return false;
    }
    let _ = writeln!(out, "\nPush has {}:", plural(problems.len(), "problem"));
    for problem in problems {
        let _ = writeln!(out, "  {problem}");
    }
    true
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
    use crate::api::CodeStorageCaps;
    use std::fs;

    fn caps(enabled: bool, required: bool) -> Capabilities {
        Capabilities {
            code_storage: CodeStorageCaps {
                enabled,
                required,
                supported_object_formats: vec!["sha1".to_string()],
            },
        }
    }

    #[test]
    fn code_policy_matrix() {
        // Old server (no capabilities endpoint).
        assert_eq!(
            code_policy(None, false, "sha1").unwrap(),
            CodePolicy::Disabled
        );
        assert_eq!(
            code_policy(None, true, "sha1").unwrap(),
            CodePolicy::Disabled
        );
        // Enabled, optional.
        assert_eq!(
            code_policy(Some(&caps(true, false)), false, "sha1").unwrap(),
            CodePolicy::Optional
        );
        // Flag skips upload when the server does not require it.
        assert_eq!(
            code_policy(Some(&caps(true, false)), true, "sha1").unwrap(),
            CodePolicy::Disabled
        );
        // Required.
        assert_eq!(
            code_policy(Some(&caps(true, true)), false, "sha1").unwrap(),
            CodePolicy::Required
        );
        // Required + flag is a hard error.
        assert!(code_policy(Some(&caps(true, true)), true, "sha1").is_err());
        // Advertised but disabled.
        assert_eq!(
            code_policy(Some(&caps(false, false)), false, "sha1").unwrap(),
            CodePolicy::Disabled
        );
        // Unsupported object format: diff-only when optional, error when required.
        assert_eq!(
            code_policy(Some(&caps(true, false)), false, "sha256").unwrap(),
            CodePolicy::Disabled
        );
        assert!(code_policy(Some(&caps(true, true)), false, "sha256").is_err());
    }

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
