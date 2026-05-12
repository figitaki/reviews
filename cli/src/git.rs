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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapturedDiff {
    pub raw_diff: String,
    pub base_sha: String,
    pub branch_name: String,
    pub source: DiffSource,
}

/// Run `git` with the given args inside `repo`, returning stdout on success.
fn run_git(repo: &Path, args: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo)
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

    if let Some(range) = range {
        let (start, _end) = split_range(range);
        let base_sha = rev_parse(repo, start)
            .with_context(|| format!("could not resolve `{start}` (from --range {range})"))?;
        let raw_diff = run_git(repo, &["diff", range])
            .with_context(|| format!("`git diff {range}` failed"))?;
        if raw_diff.trim().is_empty() {
            bail!("no changes in range {range}");
        }
        return Ok(CapturedDiff {
            raw_diff,
            base_sha,
            branch_name,
            source: DiffSource::Range(range.to_string()),
        });
    }

    // Default: HEAD~1..HEAD if HEAD~1 resolves.
    if let Some(base_sha) = try_run_git(repo, &["rev-parse", "HEAD~1"]) {
        let base_sha = base_sha.trim().to_string();
        let raw_diff = run_git(repo, &["diff", "HEAD~1..HEAD"])?;
        if !raw_diff.trim().is_empty() {
            return Ok(CapturedDiff {
                raw_diff,
                base_sha,
                branch_name,
                source: DiffSource::Range("HEAD~1..HEAD".to_string()),
            });
        }
    }

    // Fallback: staged-vs-HEAD.
    let cached = run_git(repo, &["diff", "--cached"]).unwrap_or_default();
    if !cached.trim().is_empty() {
        let base_sha = rev_parse(repo, "HEAD").unwrap_or_else(|_| String::new());
        return Ok(CapturedDiff {
            raw_diff: cached,
            base_sha,
            branch_name,
            source: DiffSource::Cached,
        });
    }

    Err(anyhow!(
        "no changes to push: HEAD~1..HEAD is empty (or HEAD~1 doesn't exist) and no staged changes. \
         Specify --range <git-range>, commit something, or `git add` your changes."
    ))
}

/// Extract the "start" of a range like `a..b` or `a...b`. If no separator, the
/// whole string is the start (single-rev case — caller decides if that's valid).
fn split_range(range: &str) -> (&str, &str) {
    if let Some(idx) = range.find("...") {
        (&range[..idx], &range[idx + 3..])
    } else if let Some(idx) = range.find("..") {
        (&range[..idx], &range[idx + 2..])
    } else {
        (range, range)
    }
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
    fn split_range_handles_dotdot_and_dotdotdot() {
        assert_eq!(split_range("a..b"), ("a", "b"));
        assert_eq!(split_range("a...b"), ("a", "b"));
        assert_eq!(split_range("HEAD"), ("HEAD", "HEAD"));
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
}
