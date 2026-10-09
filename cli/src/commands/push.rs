use anyhow::{bail, Context, Result};
use clap::Args;
use std::env;
use std::path::PathBuf;

use crate::api::{
    api_error_code, ApiClient, Capabilities, CodeSnapshotResult, CreatePatchsetRequest,
    CreateReviewRequest, ReserveSnapshotRequest,
};
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

    /// Skip uploading repository code for this push (diff only).
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
    let cfg = Config::load()?;
    let cwd = env::current_dir().context("could not read current directory")?;
    let cap = git::capture_diff(&cwd, args.range.as_deref())?;
    let packet = load_packet_for_push(&cwd, &cap.branch_name, args.packet.as_ref(), &cap.raw_diff)?;

    let client = ApiClient::new(&cfg.default.server_url, &cfg.default.api_token)?;

    eprintln!(
        "Captured diff: {} on branch {} (base {}).",
        cap.source.describe(),
        cap.branch_name,
        short_sha(&cap.base_sha),
    );

    let caps = client.capabilities()?;
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
                packet: packet.as_ref(),
                code_snapshot_id: snapshot_id.as_deref(),
            };
            let resp = client.create_patchset(&slug, &req)?;
            warn_if_skipped(resp.code_snapshot.as_ref());
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
    repo: &std::path::Path,
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

fn load_packet_for_push(
    cwd: &std::path::Path,
    branch_name: &str,
    explicit_path: Option<&PathBuf>,
    raw_diff: &str,
) -> Result<Option<serde_json::Value>> {
    let path = match explicit_path {
        Some(path) => Some(path.clone()),
        None => packet::discover_packet(cwd, branch_name),
    };

    match path {
        Some(path) => Ok(Some(packet::load_packet_for_diff(&path, raw_diff)?)),
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
