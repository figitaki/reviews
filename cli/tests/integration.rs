//! Black-box CLI tests. We invoke the built binary via `env!("CARGO_BIN_EXE_reviews")`,
//! which Cargo provides for integration tests under `tests/`.

use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_reviews"))
}

#[test]
fn help_prints_usage() {
    let out = bin().arg("--help").output().expect("run --help");
    assert!(out.status.success(), "--help failed: {:?}", out);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("reviews"), "stdout = {stdout}");
    assert!(stdout.contains("push"), "stdout = {stdout}");
    assert!(stdout.contains("whoami"), "stdout = {stdout}");
    assert!(stdout.contains("login"), "stdout = {stdout}");
    assert!(stdout.contains("diff"), "stdout = {stdout}");
}

#[test]
fn subcommand_help_works_for_push() {
    let out = bin()
        .args(["push", "--help"])
        .output()
        .expect("push --help");
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("--range"), "stdout = {stdout}");
    assert!(stdout.contains("--update"), "stdout = {stdout}");
    assert!(stdout.contains("--title"), "stdout = {stdout}");
    assert!(stdout.contains("--no-code-storage"), "stdout = {stdout}");
}

mod push_harness {
    use super::bin;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Output};

    /// A fake home directory holding the CLI config, plus a git repo with one
    /// pushable commit pair.
    pub struct Harness {
        _home: tempfile::TempDir,
        home_path: PathBuf,
        _repo_dir: tempfile::TempDir,
        pub repo: PathBuf,
    }

    fn git(repo: &Path, args: &[&str]) {
        let out = Command::new("git")
            .args(args)
            .current_dir(repo)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&out.stderr)
        );
    }

    impl Harness {
        pub fn new(server_url: &str) -> Self {
            let home = tempfile::tempdir().unwrap();
            let config_dir = home.path().join(".config").join("reviews");
            fs::create_dir_all(&config_dir).unwrap();
            fs::write(
                config_dir.join("config.toml"),
                format!("[default]\nserver_url = \"{server_url}\"\napi_token = \"tok\"\n"),
            )
            .unwrap();

            let repo_dir = tempfile::tempdir().unwrap();
            let repo = repo_dir.path().to_path_buf();
            git(&repo, &["init", "-q", "-b", "main"]);
            git(&repo, &["config", "user.email", "t@t"]);
            git(&repo, &["config", "user.name", "T"]);
            git(&repo, &["config", "commit.gpgsign", "false"]);
            fs::write(repo.join("a.txt"), "one\n").unwrap();
            git(&repo, &["add", "a.txt"]);
            git(&repo, &["commit", "-q", "-m", "c1"]);
            fs::write(repo.join("a.txt"), "one\ntwo\n").unwrap();
            git(&repo, &["add", "a.txt"]);
            git(&repo, &["commit", "-q", "-m", "c2"]);

            Harness {
                home_path: home.path().to_path_buf(),
                _home: home,
                _repo_dir: repo_dir,
                repo,
            }
        }

        pub fn push(&self, extra_args: &[&str]) -> Output {
            bin()
                .arg("push")
                .args(extra_args)
                .current_dir(&self.repo)
                .env("HOME", &self.home_path)
                .env("XDG_CONFIG_HOME", self.home_path.join(".config"))
                .output()
                .expect("run push")
        }
    }

    pub fn review_created_body() -> &'static str {
        r#"{"id":1,"slug":"abc123","url":"http://localhost:4000/r/abc123","patchset_number":1}"#
    }
}

#[test]
fn push_against_old_server_is_diff_only() {
    let mut server = mockito::Server::new();
    // Old server: no capabilities route.
    let caps = server
        .mock("GET", "/api/v1/capabilities")
        .with_status(404)
        .create();
    let create = server
        .mock("POST", "/api/v1/reviews")
        .match_header("authorization", "Bearer tok")
        .with_status(201)
        .with_header("content-type", "application/json")
        .with_body(push_harness::review_created_body())
        .create();

    let h = push_harness::Harness::new(&server.url());
    let out = h.push(&[]);

    assert!(out.status.success(), "push failed: {out:?}");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stdout.contains("Review created"), "stdout = {stdout}");
    assert!(!stderr.contains("warning:"), "stderr = {stderr}");
    caps.assert();
    create.assert();
}

#[test]
fn push_with_optional_policy_warns_and_falls_back_on_reserve_failure() {
    let mut server = mockito::Server::new();
    let _caps = server
        .mock("GET", "/api/v1/capabilities")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(
            r#"{"code_storage":{"enabled":true,"required":false,"supported_object_formats":["sha1"],"max_upload_bytes":1},"lsp":{"enabled":false,"languages":[]}}"#,
        )
        .create();
    let _reserve = server
        .mock("POST", "/api/v1/code-snapshots")
        .with_status(502)
        .with_body(r#"{"errors":{"detail":"code storage unavailable"}}"#)
        .create();
    // The review is still created — without a code_snapshot_id (the field is
    // omitted entirely when no snapshot was uploaded; see the api.rs unit test).
    let create = server
        .mock("POST", "/api/v1/reviews")
        .match_body(mockito::Matcher::Regex("raw_diff".to_string()))
        .with_status(201)
        .with_header("content-type", "application/json")
        .with_body(push_harness::review_created_body())
        .create();

    let h = push_harness::Harness::new(&server.url());
    let out = h.push(&[]);

    assert!(out.status.success(), "push failed: {out:?}");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("warning: code snapshot upload failed"),
        "stderr = {stderr}"
    );
    create.assert();
}

#[test]
fn push_uploads_snapshot_and_never_prints_the_token() {
    // The "remote" is a local bare repo; the reserve response points at it.
    let bare_dir = tempfile::tempdir().unwrap();
    let bare = bare_dir.path();
    let out = std::process::Command::new("git")
        .args(["init", "-q", "--bare"])
        .current_dir(bare)
        .output()
        .unwrap();
    assert!(out.status.success());

    let mut server = mockito::Server::new();
    let _caps = server
        .mock("GET", "/api/v1/capabilities")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(
            r#"{"code_storage":{"enabled":true,"required":true,"supported_object_formats":["sha1"],"max_upload_bytes":1},"lsp":{"enabled":false,"languages":[]}}"#,
        )
        .create();
    let reserve = server
        .mock("POST", "/api/v1/code-snapshots")
        .with_status(201)
        .with_header("content-type", "application/json")
        .with_body(format!(
            r#"{{"id":"snap-1","repository_id":"repo-1","expires_at":"x",
                "upload":{{"remote_url":"{}","token":"SECRET-UPLOAD-TOKEN","expires_at":"y"}},
                "refs":{{"base":"refs/heads/snapshots/snap-1/base","head":"refs/heads/snapshots/snap-1/head"}}}}"#,
            bare.display()
        ))
        .create();
    let complete = server
        .mock("POST", "/api/v1/code-snapshots/snap-1/complete")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"id":"snap-1","status":"ready","base_oid":"a","head_oid":"b"}"#)
        .create();
    let create = server
        .mock("POST", "/api/v1/reviews")
        .match_body(mockito::Matcher::PartialJson(serde_json::json!({
            "code_snapshot_id": "snap-1"
        })))
        .with_status(201)
        .with_header("content-type", "application/json")
        .with_body(
            r#"{"id":1,"slug":"abc123","url":"http://localhost:4000/r/abc123","patchset_number":1,
                "code_snapshot":{"status":"claimed","id":"snap-1"}}"#,
        )
        .create();

    let h = push_harness::Harness::new(&server.url());
    let out = h.push(&[]);

    assert!(out.status.success(), "push failed: {out:?}");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !stdout.contains("SECRET-UPLOAD-TOKEN") && !stderr.contains("SECRET-UPLOAD-TOKEN"),
        "token leaked to output"
    );
    assert!(
        stderr.contains("Uploading code snapshot"),
        "stderr = {stderr}"
    );

    // Both refs actually landed in the "remote".
    let refs = std::process::Command::new("git")
        .args(["for-each-ref", "--format=%(refname)"])
        .current_dir(bare)
        .output()
        .unwrap();
    let refs = String::from_utf8_lossy(&refs.stdout);
    assert!(
        refs.contains("refs/heads/snapshots/snap-1/base"),
        "refs = {refs}"
    );
    assert!(
        refs.contains("refs/heads/snapshots/snap-1/head"),
        "refs = {refs}"
    );

    reserve.assert();
    complete.assert();
    create.assert();
}

#[test]
fn push_with_required_policy_aborts_on_upload_failure() {
    let mut server = mockito::Server::new();
    let _caps = server
        .mock("GET", "/api/v1/capabilities")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(
            r#"{"code_storage":{"enabled":true,"required":true,"supported_object_formats":["sha1"],"max_upload_bytes":1},"lsp":{"enabled":false,"languages":[]}}"#,
        )
        .create();
    let _reserve = server
        .mock("POST", "/api/v1/code-snapshots")
        .with_status(502)
        .with_body(r#"{"errors":{"detail":"code storage unavailable"}}"#)
        .create();
    // The review create endpoint must never be hit.
    let create = server.mock("POST", "/api/v1/reviews").expect(0).create();

    let h = push_harness::Harness::new(&server.url());
    let out = h.push(&[]);

    assert!(!out.status.success(), "push should abort: {out:?}");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("requires code storage"),
        "stderr = {stderr}"
    );
    create.assert();
}
