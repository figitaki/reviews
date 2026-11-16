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
fn push_continues_diff_only_when_capabilities_check_fails() {
    let mut server = mockito::Server::new();
    let caps = server
        .mock("GET", "/api/v1/capabilities")
        .with_status(502)
        .create();
    let create = server
        .mock("POST", "/api/v1/reviews")
        .with_status(201)
        .with_header("content-type", "application/json")
        .with_body(push_harness::review_created_body())
        .create();

    let h = push_harness::Harness::new(&server.url());
    let out = h.push(&[]);

    assert!(out.status.success(), "push failed: {out:?}");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("pushing diff only"), "stderr = {stderr}");
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

#[test]
fn push_help_lists_dry_run_and_validate_alias() {
    let out = bin()
        .args(["push", "--help"])
        .output()
        .expect("push --help");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("--dry-run"), "stdout = {stdout}");
    assert!(stdout.contains("validate"), "stdout = {stdout}");
}

// ---- push --dry-run -------------------------------------------------------

mod dry_run {
    use super::bin;
    use mockito::{Matcher, Mock, Server, ServerGuard};
    use std::fs;
    use std::path::Path;
    use std::process::{Command, Output};

    const VALID_PACKET: &str = "# Greeting change\n\nWhy this matters.\n\n## Code\nSwap the greeting.\n\n@hunk src/hello.txt#1\n\n## Docs\n@hunk README.md#1\n";

    fn git(repo: &Path, args: &[&str]) {
        let out = Command::new("git")
            .args([
                "-c",
                "commit.gpgsign=false",
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.com",
            ])
            .args(args)
            .current_dir(repo)
            .output()
            .expect("run git");
        assert!(out.status.success(), "git {args:?} failed: {out:?}");
    }

    /// A repo whose HEAD~1..HEAD diff changes two files, one hunk each.
    fn repo() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path();
        git(repo, &["init", "-q", "-b", "feature/greeting"]);
        fs::create_dir_all(repo.join("src")).unwrap();
        fs::write(repo.join("src/hello.txt"), "hello\n").unwrap();
        fs::write(repo.join("README.md"), "# Demo\n").unwrap();
        git(repo, &["add", "."]);
        git(repo, &["commit", "-q", "-m", "base"]);
        fs::write(repo.join("src/hello.txt"), "hello, world\n").unwrap();
        fs::write(repo.join("README.md"), "# Demo\n\nSays hello.\n").unwrap();
        git(repo, &["add", "."]);
        git(repo, &["commit", "-q", "-m", "change"]);
        dir
    }

    /// A HOME whose config points at `server_url`.
    fn home(server_url: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let cfg_dir = dir.path().join(".config").join("reviews");
        fs::create_dir_all(&cfg_dir).unwrap();
        fs::write(
            cfg_dir.join("config.toml"),
            format!("[default]\nserver_url = \"{server_url}\"\napi_token = \"tok\"\n"),
        )
        .unwrap();
        dir
    }

    /// Mocks that fail the test if the CLI sends any request at all.
    fn refuse_all_requests(server: &mut ServerGuard) -> Vec<Mock> {
        ["GET", "POST", "PATCH", "PUT", "DELETE"]
            .into_iter()
            .map(|method| {
                server
                    .mock(method, Matcher::Any)
                    .with_status(500)
                    .expect(0)
                    .create()
            })
            .collect()
    }

    fn push(repo: &Path, home: &Path, args: &[&str]) -> Output {
        bin()
            .arg("push")
            .args(args)
            .current_dir(repo)
            .env("HOME", home)
            .output()
            .expect("run reviews push")
    }

    fn write_packet(repo: &Path, body: &str) {
        let dir = repo.join(".reviews").join("feature__greeting");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("packet.md"), body).unwrap();
    }

    #[test]
    fn quoted_filenames_are_listed_and_checked_without_requests() {
        let mut server = Server::new();
        let mocks = refuse_all_requests(&mut server);
        let repo = repo();
        let home = home(&server.url());
        git(repo.path(), &["config", "core.quotePath", "true"]);
        fs::write(repo.path().join("café.png"), b"\0binary").unwrap();
        fs::write(repo.path().join("café.txt"), "hello\n").unwrap();
        git(repo.path(), &["add", "."]);
        git(repo.path(), &["commit", "-q", "-m", "quoted files"]);
        write_packet(repo.path(), "# Quoted files\n\n## Text\n@hunk café.txt#1\n");

        let out = push(repo.path(), home.path(), &["--dry-run"]);
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "out = {out:?}");
        assert!(stdout.contains("2 files, 1 hunk"), "{stdout}");
        assert!(stdout.contains("café.png  0 hunks"), "{stdout}");
        assert!(stdout.contains("café.txt  1 hunk"), "{stdout}");
        assert!(stdout.contains("Packet is valid"), "{stdout}");

        write_packet(
            repo.path(),
            "# Quoted files\n\n## Text\nMissing coverage.\n",
        );
        let out = push(repo.path(), home.path(), &["--dry-run"]);
        assert_eq!(out.status.code(), Some(1), "out = {out:?}");
        assert!(String::from_utf8_lossy(&out.stdout).contains("café.txt"));
        for mock in mocks {
            mock.assert();
        }
    }

    #[test]
    fn valid_packet_prints_what_would_be_sent_and_sends_nothing() {
        let mut server = Server::new();
        let mocks = refuse_all_requests(&mut server);
        let repo = repo();
        let home = home(&server.url());
        write_packet(repo.path(), VALID_PACKET);

        let out = push(
            repo.path(),
            home.path(),
            &["--dry-run", "--title", "Say hello"],
        );
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "out = {out:?}");
        assert!(stdout.contains("nothing was sent"), "stdout = {stdout}");
        assert!(
            stdout.contains(&format!("Server:  {}", server.url())),
            "stdout = {stdout}"
        );
        assert!(
            stdout.contains("create a new review titled \"Say hello\" (from --title)"),
            "stdout = {stdout}"
        );
        assert!(
            stdout.contains("range HEAD~1..HEAD on branch feature/greeting"),
            "stdout = {stdout}"
        );
        assert!(stdout.contains("2 files, 2 hunks"), "stdout = {stdout}");
        assert!(
            stdout.contains("Packet:  .reviews/feature__greeting/packet.md"),
            "stdout = {stdout}"
        );
        assert!(
            stdout.contains("title: Greeting change"),
            "stdout = {stdout}"
        );
        assert!(
            stdout.contains("2 sections, 2 hunk refs across 2 files"),
            "stdout = {stdout}"
        );
        assert!(stdout.contains("1. Code  1 hunk ref"), "stdout = {stdout}");
        assert!(stdout.contains("Packet is valid."), "stdout = {stdout}");
        for mock in mocks {
            mock.assert();
        }
    }

    #[test]
    fn validate_alias_with_update_names_the_target_review() {
        let mut server = Server::new();
        let mocks = refuse_all_requests(&mut server);
        let repo = repo();
        let home = home(&server.url());
        write_packet(repo.path(), VALID_PACKET);

        let out = push(
            repo.path(),
            home.path(),
            &["--validate", "--update", "k7m2qz"],
        );
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "out = {out:?}");
        assert!(
            stdout.contains("add a new patchset to review k7m2qz"),
            "stdout = {stdout}"
        );
        for mock in mocks {
            mock.assert();
        }
    }

    #[test]
    fn invalid_packet_lists_every_problem_and_exits_nonzero() {
        let mut server = Server::new();
        let mocks = refuse_all_requests(&mut server);
        let repo = repo();
        let home = home(&server.url());
        let packet = repo.path().join("bad.md");
        fs::write(
            &packet,
            "# Bad\n\n## Code\n@hunk src/hello.txt#2\n@hunk src/missing.txt#1\n@hunk README.md\n",
        )
        .unwrap();

        let out = push(
            repo.path(),
            home.path(),
            &["--dry-run", "--packet", packet.to_str().unwrap()],
        );
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(1), "out = {out:?}");
        assert!(
            stdout.contains("Packet has 5 problems:"),
            "stdout = {stdout}"
        );
        assert!(
            stdout.contains("bad.md:4: packet references unknown hunk `src/hello.txt#2`"),
            "stdout = {stdout}"
        );
        assert!(
            stdout.contains("bad.md:5: packet references unknown file `src/missing.txt`"),
            "stdout = {stdout}"
        );
        assert!(
            stdout.contains("bad.md:6: hunk refs must look like"),
            "stdout = {stdout}"
        );
        assert!(
            stdout.contains("bad.md: packet does not cover changed lines `README.md`#1"),
            "stdout = {stdout}"
        );
        assert!(
            stdout.contains("bad.md: packet does not cover changed lines `src/hello.txt`#1"),
            "stdout = {stdout}"
        );
        assert!(
            stderr.contains("a real push would fail"),
            "stderr = {stderr}"
        );
        for mock in mocks {
            mock.assert();
        }
    }

    #[test]
    fn missing_config_is_reported_but_does_not_fail_the_check() {
        let repo = repo();
        let home = tempfile::tempdir().unwrap();
        write_packet(repo.path(), VALID_PACKET);

        let out = push(repo.path(), home.path(), &["--dry-run"]);
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "out = {out:?}");
        assert!(
            stdout.contains("Server:  not set. A real push will fail"),
            "stdout = {stdout}"
        );
        assert!(stdout.contains("reviews login"), "stdout = {stdout}");
        assert!(
            !home.path().join(".config").exists(),
            "dry run wrote config"
        );
    }

    #[test]
    fn real_push_refuses_the_same_invalid_packet_before_any_request() {
        let mut server = Server::new();
        let mocks = refuse_all_requests(&mut server);
        let repo = repo();
        let home = home(&server.url());
        write_packet(repo.path(), "# Bad\n\n## Code\n@hunk src/hello.txt#2\n");

        let out = push(repo.path(), home.path(), &[]);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(1), "out = {out:?}");
        assert!(
            stderr.contains("packet.md:4: packet references unknown hunk"),
            "stderr = {stderr}"
        );
        for mock in mocks {
            mock.assert();
        }
    }

    #[test]
    fn blank_title_fails_the_dry_run_and_the_real_push_without_a_request() {
        let mut server = Server::new();
        let mocks = refuse_all_requests(&mut server);
        let repo = repo();
        let home = home(&server.url());
        write_packet(repo.path(), VALID_PACKET);

        let out = push(repo.path(), home.path(), &["--dry-run", "--title", "  "]);
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(1), "out = {out:?}");
        assert!(stdout.contains("Push has 1 problem:"), "stdout = {stdout}");
        assert!(
            stdout.contains("the review title is empty"),
            "stdout = {stdout}"
        );
        assert!(
            !stdout.contains("without --dry-run to push it"),
            "stdout = {stdout}"
        );
        assert!(
            stderr.contains("a real push would fail"),
            "stderr = {stderr}"
        );

        let out = push(repo.path(), home.path(), &["--title", ""]);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(1), "out = {out:?}");
        assert!(
            stderr.contains("the review title is empty"),
            "stderr = {stderr}"
        );

        let out = push(repo.path(), home.path(), &["--update", ""]);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(1), "out = {out:?}");
        assert!(
            stderr.contains("--update needs a review slug"),
            "stderr = {stderr}"
        );
        for mock in mocks {
            mock.assert();
        }
    }

    /// Control for the tests above: the same setup without --dry-run does
    /// reach the fake server, so `expect(0)` there means something.
    #[test]
    fn real_push_with_valid_packet_reaches_the_server() {
        let mut server = Server::new();
        let create = server
            .mock("POST", "/api/v1/reviews")
            .with_status(201)
            .with_header("content-type", "application/json")
            .with_body(r#"{"id":1,"slug":"abc123","url":"http://x/r/abc123","patchset_number":1}"#)
            .expect(1)
            .create();
        let repo = repo();
        let home = home(&server.url());
        write_packet(repo.path(), VALID_PACKET);

        let out = push(repo.path(), home.path(), &[]);
        assert!(out.status.success(), "out = {out:?}");
        create.assert();
    }
}
