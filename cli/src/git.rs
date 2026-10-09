//! Thin shell-out helpers around `git`. We avoid libgit2 to keep the build simple.

use anyhow::{anyhow, bail, Context, Result};
use std::path::Path;
use std::process::Command;

/// What we ended up diffing — used to format friendly status output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffSource {
    /// An explicit `git diff <range>` (e.g. `HEAD~1..HEAD`).
    Range(String),
    /// `git diff --cached` — staged-vs-HEAD.
    Cached,
}

impl DiffSource {
    pub fn describe(&self) -> String {
        match self {
            DiffSource::Range(r) => format!("range {r}"),
            DiffSource::Cached => "staged changes (--cached)".to_string(),
        }
    }
}

/// What the "new side" of the diff is. A `Commit` head can be uploaded as-is;
/// `Index` and `Worktree` heads need a synthetic commit before upload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HeadSource {
    Commit(String),
    Index,
    Worktree,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapturedDiff {
    pub raw_diff: String,
    pub base_sha: String,
    pub branch_name: String,
    pub source: DiffSource,
    /// Full commit OID of the old side; empty only for pre-first-commit repos.
    pub base_oid: String,
    pub head: HeadSource,
    /// `sha1` or `sha256` (`git rev-parse --show-object-format`).
    pub object_format: String,
}

/// Run `git` with the given args inside `repo`, returning stdout on success.
fn run_git(repo: &Path, args: &[&str]) -> Result<String> {
    run_git_env(repo, args, &[])
}

/// Like `run_git`, with extra environment variables. Error text includes the
/// args only — env values (credentials, temp index paths) never appear in it.
fn run_git_env(repo: &Path, args: &[&str], envs: &[(&str, &str)]) -> Result<String> {
    let mut cmd = Command::new("git");
    cmd.args(args).current_dir(repo);
    for (key, value) in envs {
        cmd.env(key, value);
    }

    let output = cmd
        .output()
        .with_context(|| format!("could not execute `git {}`", args.join(" ")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!(
            "`git {}` failed (exit {}): {}",
            args.join(" "),
            output.status.code().unwrap_or(-1),
            stderr.trim()
        );
    }
    String::from_utf8(output.stdout)
        .with_context(|| format!("`git {}` produced non-UTF8 output", args.join(" ")))
}

fn try_run_git(repo: &Path, args: &[&str]) -> Option<String> {
    run_git(repo, args).ok()
}

/// Canonical, config-neutral diff invocation. Local settings like
/// `diff.algorithm`, `core.quotePath`, or external diff drivers must not
/// change the bytes we upload, because the same command later verifies the
/// synthetic snapshot against `raw_diff`.
fn canonical_diff(repo: &Path, extra: &[&str]) -> Result<String> {
    let mut args = vec![
        "-c",
        "core.quotePath=false",
        "-c",
        "diff.algorithm=myers",
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--binary",
    ];
    args.extend_from_slice(extra);
    run_git(repo, &args)
}

/// Resolve a git ref (or range start) to a full SHA.
pub fn rev_parse(repo: &Path, rev: &str) -> Result<String> {
    let s = run_git(repo, &["rev-parse", rev])?;
    Ok(s.trim().to_string())
}

/// Current branch (or "HEAD" if detached).
pub fn current_branch(repo: &Path) -> Result<String> {
    let s = run_git(repo, &["rev-parse", "--abbrev-ref", "HEAD"])?;
    Ok(s.trim().to_string())
}

/// Capture a diff. Algorithm:
///   - If `range` provided, use it (`git diff <range>`).
///   - Else if `HEAD~1` resolves, use `HEAD~1..HEAD`.
///   - Else if `git diff --cached` is non-empty, use that.
///   - Else error.
pub fn capture_diff(repo: &Path, range: Option<&str>) -> Result<CapturedDiff> {
    // Sanity check: we need a git repo.
    if run_git(repo, &["rev-parse", "--is-inside-work-tree"]).is_err() {
        bail!(
            "not inside a git repository (cwd: {}). Run from your project directory.",
            repo.display()
        );
    }

    let branch_name = current_branch(repo).unwrap_or_else(|_| "HEAD".to_string());
    let object_format = object_format(repo);

    if let Some(range) = range {
        let (base_oid, head) = resolve_range(repo, range)?;
        let raw_diff =
            canonical_diff(repo, &[range]).with_context(|| format!("`git diff {range}` failed"))?;
        if raw_diff.trim().is_empty() {
            bail!("no changes in range {range}");
        }
        return Ok(CapturedDiff {
            raw_diff,
            base_sha: base_oid.clone(),
            branch_name,
            source: DiffSource::Range(range.to_string()),
            base_oid,
            head,
            object_format,
        });
    }

    // Default: HEAD~1..HEAD if HEAD~1 resolves.
    if let Some(base_sha) = try_run_git(repo, &["rev-parse", "HEAD~1"]) {
        let base_oid = base_sha.trim().to_string();
        let raw_diff = canonical_diff(repo, &["HEAD~1..HEAD"])?;
        if !raw_diff.trim().is_empty() {
            let head_oid = rev_parse(repo, "HEAD")?;
            return Ok(CapturedDiff {
                raw_diff,
                base_sha: base_oid.clone(),
                branch_name,
                source: DiffSource::Range("HEAD~1..HEAD".to_string()),
                base_oid,
                head: HeadSource::Commit(head_oid),
                object_format,
            });
        }
    }

    // Fallback: staged-vs-HEAD.
    let cached = canonical_diff(repo, &["--cached"]).unwrap_or_default();
    if !cached.trim().is_empty() {
        // Pre-first-commit repos legitimately have no base; base_sha stays
        // empty and code upload is skipped for such pushes.
        let base_oid = rev_parse(repo, "HEAD").unwrap_or_default();
        return Ok(CapturedDiff {
            raw_diff: cached,
            base_sha: base_oid.clone(),
            branch_name,
            source: DiffSource::Cached,
            base_oid,
            head: HeadSource::Index,
            object_format,
        });
    }

    Err(anyhow!(
        "no changes to push: HEAD~1..HEAD is empty (or HEAD~1 doesn't exist) and no staged changes. \
         Specify --range <git-range>, commit something, or `git add` your changes."
    ))
}

/// Resolve a `--range` argument to exact base OID and head source.
///
/// `A...B` diffs from the merge base of A and B, so that (not A itself) is
/// the base commit. A single revision `X` means worktree-vs-X.
fn resolve_range(repo: &Path, range: &str) -> Result<(String, HeadSource)> {
    if let Some(idx) = range.find("...") {
        let (a, b) = (&range[..idx], &range[idx + 3..]);
        let base = run_git(repo, &["merge-base", a, b])
            .with_context(|| format!("could not resolve merge base of `{a}` and `{b}`"))?
            .trim()
            .to_string();
        let head = rev_parse_commit(repo, b)?;
        Ok((base, HeadSource::Commit(head)))
    } else if let Some(idx) = range.find("..") {
        let (a, b) = (&range[..idx], &range[idx + 2..]);
        let base = rev_parse_commit(repo, a)
            .with_context(|| format!("could not resolve `{a}` (from --range {range})"))?;
        let head = rev_parse_commit(repo, b)?;
        Ok((base, HeadSource::Commit(head)))
    } else {
        let base = rev_parse_commit(repo, range)
            .with_context(|| format!("could not resolve `{range}`"))?;
        Ok((base, HeadSource::Worktree))
    }
}

fn rev_parse_commit(repo: &Path, rev: &str) -> Result<String> {
    let s = run_git(repo, &["rev-parse", &format!("{rev}^{{commit}}")])?;
    Ok(s.trim().to_string())
}

fn object_format(repo: &Path) -> String {
    try_run_git(repo, &["rev-parse", "--show-object-format"])
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "sha1".to_string())
}

// --- Snapshot commits ------------------------------------------------------

/// Fixed identity for synthetic transport commits. Never the developer's
/// local git name or email.
const SNAPSHOT_NAME: &str = "Reviews Snapshot";
const SNAPSHOT_EMAIL: &str = "snapshot@reviews.invalid";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotCommits {
    pub base_oid: String,
    pub head_oid: String,
    /// `commit`, `index_snapshot`, or `worktree_snapshot` — the wire value
    /// for the reserve request.
    pub head_kind: &'static str,
}

/// Produce the exact base/head commits for a captured diff, creating a
/// synthetic commit for staged or tracked-worktree state. Never touches the
/// user's branches or real index.
///
/// Before returning, verifies that the canonical diff between the two commits
/// reproduces `cap.raw_diff` byte-for-byte (modulo one trailing newline), so
/// the rendered diff and the uploaded workspace are two views of the same
/// objects.
pub fn create_snapshot_commits(repo: &Path, cap: &CapturedDiff) -> Result<SnapshotCommits> {
    if cap.base_oid.is_empty() {
        bail!("cannot snapshot code without a base commit (repository has no commits yet)");
    }

    let (head_oid, head_kind) = match &cap.head {
        HeadSource::Commit(oid) => (oid.clone(), "commit"),
        HeadSource::Index => (
            synthetic_commit(repo, &cap.base_oid, false)?,
            "index_snapshot",
        ),
        HeadSource::Worktree => (
            synthetic_commit(repo, &cap.base_oid, true)?,
            "worktree_snapshot",
        ),
    };

    // Both endpoints must be commit objects.
    rev_parse_commit(repo, &cap.base_oid).context("snapshot base is not a commit")?;
    rev_parse_commit(repo, &head_oid).context("snapshot head is not a commit")?;

    // The invariant: the diff we rendered is the diff between the snapshots.
    let range = format!("{}..{}", cap.base_oid, head_oid);
    let replayed = canonical_diff(repo, &[&range])?;
    if normalize_final_newline(&replayed) != normalize_final_newline(&cap.raw_diff) {
        bail!(
            "snapshot verification failed: `git diff {}` does not match the captured diff. \
             Not uploading mismatched code refs.",
            range
        );
    }

    Ok(SnapshotCommits {
        base_oid: cap.base_oid.clone(),
        head_oid,
        head_kind,
    })
}

/// Build a commit object from the index (staged state), or from the index
/// plus tracked worktree changes when `include_worktree`. Uses a temporary
/// index file so the user's real index is never modified.
fn synthetic_commit(repo: &Path, base_oid: &str, include_worktree: bool) -> Result<String> {
    let real_index = run_git(repo, &["rev-parse", "--git-path", "index"])?
        .trim()
        .to_string();
    let real_index_path = repo.join(&real_index);

    let temp = tempfile::Builder::new()
        .prefix("reviews-snapshot-index-")
        .tempfile()
        .context("could not create temporary index")?;
    let temp_index = temp.path().to_path_buf();
    // Start from the real index so staged additions are included.
    std::fs::copy(&real_index_path, &temp_index).context("could not copy git index")?;
    let temp_index_str = temp_index
        .to_str()
        .context("temporary index path is not UTF-8")?;

    let index_env: &[(&str, &str)] = &[("GIT_INDEX_FILE", temp_index_str)];

    if include_worktree {
        // Stage tracked modifications and deletions only — never untracked
        // or ignored files.
        run_git_env(repo, &["add", "-u"], index_env)?;
    }

    let tree = run_git_env(repo, &["write-tree"], index_env)?
        .trim()
        .to_string();

    // Fixed author/committer identity and a message with no local paths or
    // remote names: this commit is only a transport snapshot.
    let commit = run_git_env(
        repo,
        &[
            "commit-tree",
            &tree,
            "-p",
            base_oid,
            "-m",
            "Reviews snapshot",
        ],
        &[
            ("GIT_INDEX_FILE", temp_index_str),
            ("GIT_AUTHOR_NAME", SNAPSHOT_NAME),
            ("GIT_AUTHOR_EMAIL", SNAPSHOT_EMAIL),
            ("GIT_COMMITTER_NAME", SNAPSHOT_NAME),
            ("GIT_COMMITTER_EMAIL", SNAPSHOT_EMAIL),
        ],
    )?
    .trim()
    .to_string();

    Ok(commit)
}

fn normalize_final_newline(s: &str) -> &str {
    s.strip_suffix('\n').unwrap_or(s)
}

// --- Snapshot ref push -----------------------------------------------------

/// Push exactly the two reserved snapshot refs in one atomic operation.
///
/// The upload credential is passed as an HTTP header via one-shot environment
/// config — it must never appear in the remote URL, argv, git config files,
/// or error output (`run_git_env` formats args only).
pub fn push_snapshot_refs(
    repo: &Path,
    remote_url: &str,
    token: &str,
    base_oid: &str,
    base_ref: &str,
    head_oid: &str,
    head_ref: &str,
) -> Result<()> {
    let base_refspec = format!("{base_oid}:{base_ref}");
    let head_refspec = format!("{head_oid}:{head_ref}");
    let auth_value = format!(
        "Authorization: Basic {}",
        base64_encode(format!("t:{token}").as_bytes())
    );

    run_git_env(
        repo,
        &["push", "--atomic", remote_url, &base_refspec, &head_refspec],
        &[
            ("GIT_CONFIG_COUNT", "1"),
            ("GIT_CONFIG_KEY_0", "http.extraHeader"),
            ("GIT_CONFIG_VALUE_0", &auth_value),
            ("GIT_TERMINAL_PROMPT", "0"),
        ],
    )
    .map(|_| ())
    .map_err(redact_push_error)
}

/// `git push` errors echo the remote URL, which is safe (it carries no
/// credentials), but scrub anything that looks like an Authorization value
/// just in case a proxy or git version reflects headers into stderr.
fn redact_push_error(err: anyhow::Error) -> anyhow::Error {
    let msg = format!("{err:#}");
    if msg.contains("Basic ") {
        anyhow!("{}", msg.split("Basic ").next().unwrap_or("push failed"))
            .context("pushing snapshot refs failed (credential redacted)")
    } else {
        err
    }
}

/// Minimal standard-alphabet base64 (no padding shortcuts) to avoid a
/// dependency for one call site.
fn base64_encode(input: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(ALPHABET[(n >> 18 & 0x3f) as usize] as char);
        out.push(ALPHABET[(n >> 12 & 0x3f) as usize] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(n >> 6 & 0x3f) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[(n & 0x3f) as usize] as char
        } else {
            '='
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn init_repo() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_path_buf();
        run_git(&path, &["init", "-q", "-b", "main"]).unwrap();
        run_git(&path, &["config", "user.email", "t@t"]).unwrap();
        run_git(&path, &["config", "user.name", "T"]).unwrap();
        run_git(&path, &["config", "commit.gpgsign", "false"]).unwrap();
        (dir, path)
    }

    fn commit_file(repo: &Path, name: &str, contents: &str, msg: &str) {
        fs::write(repo.join(name), contents).unwrap();
        run_git(repo, &["add", name]).unwrap();
        run_git(repo, &["commit", "-q", "-m", msg]).unwrap();
    }

    #[test]
    fn capture_diff_default_uses_head1_to_head() {
        let (_g, repo) = init_repo();
        commit_file(&repo, "a.txt", "hello\n", "initial");
        commit_file(&repo, "a.txt", "hello\nworld\n", "add world");

        let cap = capture_diff(&repo, None).unwrap();
        assert!(cap.raw_diff.contains("+world"));
        assert!(!cap.base_sha.is_empty());
        assert_eq!(cap.branch_name, "main");
        assert_eq!(cap.source, DiffSource::Range("HEAD~1..HEAD".to_string()));
    }

    #[test]
    fn capture_diff_uses_explicit_range() {
        let (_g, repo) = init_repo();
        commit_file(&repo, "a.txt", "1\n", "c1");
        commit_file(&repo, "a.txt", "1\n2\n", "c2");
        commit_file(&repo, "a.txt", "1\n2\n3\n", "c3");

        let cap = capture_diff(&repo, Some("HEAD~2..HEAD")).unwrap();
        assert!(cap.raw_diff.contains("+2"));
        assert!(cap.raw_diff.contains("+3"));
        assert_eq!(cap.source, DiffSource::Range("HEAD~2..HEAD".to_string()));
    }

    #[test]
    fn capture_diff_falls_back_to_staged_when_no_history() {
        let (_g, repo) = init_repo();
        // No commits yet. Staging a file should make us fall through to --cached.
        fs::write(repo.join("a.txt"), "hello\n").unwrap();
        run_git(&repo, &["add", "a.txt"]).unwrap();

        // HEAD~1 fails, and HEAD also fails (no commits), so default path can't
        // even produce a base_sha. We still want to return the cached diff with
        // an empty-ish base_sha. The contract upstream tolerates that — base_sha
        // is metadata, not a foreign key.
        let cap = capture_diff(&repo, None).unwrap();
        assert!(cap.raw_diff.contains("+hello"));
        assert_eq!(cap.source, DiffSource::Cached);
    }

    #[test]
    fn capture_diff_errors_when_no_changes() {
        let (_g, repo) = init_repo();
        commit_file(&repo, "a.txt", "x\n", "c1");
        // Single commit: HEAD~1 doesn't resolve, nothing staged.
        let err = capture_diff(&repo, None).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("no changes"), "msg = {msg}");
    }

    #[test]
    fn capture_diff_errors_on_empty_range() {
        let (_g, repo) = init_repo();
        commit_file(&repo, "a.txt", "x\n", "c1");
        let err = capture_diff(&repo, Some("HEAD..HEAD")).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("no changes"), "msg = {msg}");
    }

    #[test]
    fn capture_diff_errors_outside_repo() {
        let dir = tempfile::tempdir().unwrap();
        let err = capture_diff(dir.path(), None).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("not inside a git repository"), "msg = {msg}");
    }

    #[test]
    fn capture_diff_resolves_dotdot_endpoints() {
        let (_g, repo) = init_repo();
        commit_file(&repo, "a.txt", "1\n", "c1");
        commit_file(&repo, "a.txt", "1\n2\n", "c2");

        let cap = capture_diff(&repo, Some("HEAD~1..HEAD")).unwrap();
        assert_eq!(cap.base_oid, rev_parse(&repo, "HEAD~1").unwrap());
        assert_eq!(cap.base_sha, cap.base_oid);
        assert_eq!(
            cap.head,
            HeadSource::Commit(rev_parse(&repo, "HEAD").unwrap())
        );
        assert_eq!(cap.object_format, "sha1");
    }

    #[test]
    fn capture_diff_triple_dot_uses_merge_base() {
        let (_g, repo) = init_repo();
        commit_file(&repo, "a.txt", "base\n", "c1");
        let fork = rev_parse(&repo, "HEAD").unwrap();
        run_git(&repo, &["checkout", "-q", "-b", "feature"]).unwrap();
        commit_file(&repo, "b.txt", "feature\n", "feat");
        run_git(&repo, &["checkout", "-q", "main"]).unwrap();
        commit_file(&repo, "c.txt", "main moved on\n", "main2");

        let cap = capture_diff(&repo, Some("main...feature")).unwrap();
        // Base is the merge base (the fork point), not `main`.
        assert_eq!(cap.base_oid, fork);
        assert_eq!(cap.base_sha, fork);
        assert_eq!(
            cap.head,
            HeadSource::Commit(rev_parse(&repo, "feature").unwrap())
        );
        // The diff shows only the feature-side change.
        assert!(cap.raw_diff.contains("+feature"));
        assert!(!cap.raw_diff.contains("main moved on"));
    }

    #[test]
    fn capture_diff_single_rev_is_worktree_head() {
        let (_g, repo) = init_repo();
        commit_file(&repo, "a.txt", "1\n", "c1");
        fs::write(repo.join("a.txt"), "1\nedited\n").unwrap();

        let cap = capture_diff(&repo, Some("HEAD")).unwrap();
        assert_eq!(cap.base_oid, rev_parse(&repo, "HEAD").unwrap());
        assert_eq!(cap.head, HeadSource::Worktree);
        assert!(cap.raw_diff.contains("+edited"));
    }

    #[test]
    fn capture_diff_is_config_neutral() {
        let (_g, repo) = init_repo();
        // Hostile local diff config must not change the uploaded bytes.
        run_git(&repo, &["config", "diff.algorithm", "patience"]).unwrap();
        run_git(&repo, &["config", "core.quotePath", "true"]).unwrap();
        commit_file(&repo, "a.txt", "1\n2\n3\n", "c1");
        commit_file(&repo, "a.txt", "1\nx\n3\n", "c2");

        let cap = capture_diff(&repo, None).unwrap();
        let commits = create_snapshot_commits(&repo, &cap).unwrap();
        assert_eq!(commits.head_kind, "commit");
    }

    #[test]
    fn snapshot_commits_for_committed_head_reuse_the_commit() {
        let (_g, repo) = init_repo();
        commit_file(&repo, "a.txt", "1\n", "c1");
        commit_file(&repo, "a.txt", "1\n2\n", "c2");

        let cap = capture_diff(&repo, None).unwrap();
        let commits = create_snapshot_commits(&repo, &cap).unwrap();
        assert_eq!(commits.base_oid, rev_parse(&repo, "HEAD~1").unwrap());
        assert_eq!(commits.head_oid, rev_parse(&repo, "HEAD").unwrap());
        assert_eq!(commits.head_kind, "commit");
    }

    #[test]
    fn index_snapshot_leaves_repo_untouched_and_matches_diff() {
        let (_g, repo) = init_repo();
        // Single commit so HEAD~1 does not resolve and the staged fallback fires.
        commit_file(&repo, "a.txt", "1\n", "c1");
        fs::write(repo.join("a.txt"), "1\nstaged\n").unwrap();
        run_git(&repo, &["add", "a.txt"]).unwrap();

        let head_before = rev_parse(&repo, "HEAD").unwrap();
        let status_before = run_git(&repo, &["status", "--porcelain"]).unwrap();

        let cap = capture_diff(&repo, None).unwrap();
        assert_eq!(cap.source, DiffSource::Cached);
        let commits = create_snapshot_commits(&repo, &cap).unwrap();
        assert_eq!(commits.head_kind, "index_snapshot");
        assert_ne!(commits.head_oid, head_before);

        // Branch and real index are untouched.
        assert_eq!(rev_parse(&repo, "HEAD").unwrap(), head_before);
        assert_eq!(
            run_git(&repo, &["status", "--porcelain"]).unwrap(),
            status_before
        );

        // Fixed synthetic identity, no local details in the message.
        let show = run_git(
            &repo,
            &[
                "show",
                "-s",
                "--format=%an <%ae>|%cn <%ce>|%s",
                &commits.head_oid,
            ],
        )
        .unwrap();
        assert_eq!(
            show.trim(),
            "Reviews Snapshot <snapshot@reviews.invalid>|Reviews Snapshot <snapshot@reviews.invalid>|Reviews snapshot"
        );
    }

    #[test]
    fn worktree_snapshot_includes_tracked_changes_only() {
        let (_g, repo) = init_repo();
        commit_file(&repo, "a.txt", "1\n", "c1");
        commit_file(&repo, "gone.txt", "bye\n", "c2");
        fs::write(repo.join("a.txt"), "1\nedited\n").unwrap();
        fs::remove_file(repo.join("gone.txt")).unwrap();
        fs::write(repo.join("untracked.txt"), "secret\n").unwrap();

        let cap = capture_diff(&repo, Some("HEAD")).unwrap();
        let commits = create_snapshot_commits(&repo, &cap).unwrap();
        assert_eq!(commits.head_kind, "worktree_snapshot");

        let tree = run_git(&repo, &["ls-tree", "-r", "--name-only", &commits.head_oid]).unwrap();
        assert!(tree.contains("a.txt"));
        assert!(!tree.contains("gone.txt"), "tracked deletion applied");
        assert!(!tree.contains("untracked.txt"), "untracked excluded");

        // Real index untouched: git still sees the worktree edits as unstaged.
        let status = run_git(&repo, &["status", "--porcelain"]).unwrap();
        assert!(status.contains(" M a.txt"), "status = {status}");
        assert!(status.contains(" D gone.txt"), "status = {status}");
    }

    #[test]
    fn snapshot_invariant_covers_binary_files() {
        let (_g, repo) = init_repo();
        commit_file(&repo, "a.txt", "1\n", "c1");
        fs::write(repo.join("blob.bin"), [0u8, 159, 146, 150, 0, 1]).unwrap();
        run_git(&repo, &["add", "blob.bin"]).unwrap();

        let cap = capture_diff(&repo, None).unwrap();
        assert!(cap.raw_diff.contains("GIT binary patch"));
        let commits = create_snapshot_commits(&repo, &cap).unwrap();
        assert_eq!(commits.head_kind, "index_snapshot");
    }

    #[test]
    fn snapshot_refuses_without_base_commit() {
        let (_g, repo) = init_repo();
        fs::write(repo.join("a.txt"), "hello\n").unwrap();
        run_git(&repo, &["add", "a.txt"]).unwrap();

        let cap = capture_diff(&repo, None).unwrap();
        assert!(cap.base_oid.is_empty());
        let err = create_snapshot_commits(&repo, &cap).unwrap_err();
        assert!(format!("{err:#}").contains("no commits yet"));
    }

    #[test]
    fn push_snapshot_refs_pushes_exactly_two_refs() {
        let (_g, repo) = init_repo();
        commit_file(&repo, "a.txt", "1\n", "c1");
        commit_file(&repo, "a.txt", "1\n2\n", "c2");
        let cap = capture_diff(&repo, None).unwrap();
        let commits = create_snapshot_commits(&repo, &cap).unwrap();

        let bare_dir = tempfile::tempdir().unwrap();
        let bare = bare_dir.path();
        run_git(bare, &["init", "-q", "--bare"]).unwrap();

        let base_ref = "refs/heads/snapshots/s1/base";
        let head_ref = "refs/heads/snapshots/s1/head";
        push_snapshot_refs(
            &repo,
            bare.to_str().unwrap(),
            "secret-token",
            &commits.base_oid,
            base_ref,
            &commits.head_oid,
            head_ref,
        )
        .unwrap();

        let refs = run_git(bare, &["for-each-ref", "--format=%(objectname) %(refname)"]).unwrap();
        let mut lines: Vec<&str> = refs.lines().collect();
        lines.sort_unstable();
        let mut expected = vec![
            format!("{} {}", commits.base_oid, base_ref),
            format!("{} {}", commits.head_oid, head_ref),
        ];
        expected.sort_unstable();
        assert_eq!(lines, expected);
    }

    #[test]
    fn base64_encodes_basic_auth() {
        assert_eq!(base64_encode(b"t:tok"), "dDp0b2s=");
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"a"), "YQ==");
        assert_eq!(base64_encode(b"ab"), "YWI=");
    }
}
