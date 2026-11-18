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

#[test]
fn comments_pin_revisions_and_replies_do_not_fetch_snapshots() {
    let mut server = mockito::Server::new();
    let config_home = tempfile::tempdir().unwrap();
    let config_dir = config_home.path().join(".config/reviews");
    std::fs::create_dir_all(&config_dir).unwrap();
    std::fs::write(
        config_dir.join("config.toml"),
        format!(
            "[default]\nserver_url = {:?}\napi_token = \"test-token\"\n",
            server.url()
        ),
    )
    .unwrap();
    let no_get = server.mock("GET", mockito::Matcher::Any).expect(0).create();
    let response = r#"{"thread_id":7,"comment_id":8,"url":"http://localhost/r/slug"}"#;
    let comment = server
        .mock("POST", "/api/v1/reviews/slug/comments")
        .match_body(mockito::Matcher::Json(serde_json::json!({
            "file_path":"foo", "side":"new", "body":"comment", "revision":2,
            "thread_anchor":{"granularity":"line", "line_number_hint":1}
        })))
        .with_status(201)
        .with_header("content-type", "application/json")
        .with_body(response)
        .create();
    let reply = server
        .mock("POST", "/api/v1/reviews/slug/comments")
        .match_body(mockito::Matcher::Json(
            serde_json::json!({"thread_id":7, "body":"reply"}),
        ))
        .with_status(201)
        .with_header("content-type", "application/json")
        .with_body(response)
        .create();
    for args in [
        vec![
            "comment",
            "slug",
            "foo:1",
            "--revision",
            "2",
            "--body",
            "comment",
        ],
        vec!["reply", "slug", "7", "--body", "reply"],
    ] {
        let output = bin()
            .args(args)
            .env("HOME", config_home.path())
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
    }
    comment.assert();
    reply.assert();
    no_get.assert();
}

mod delete {
    use super::bin;
    use mockito::{Matcher, Server};
    use std::io::Write;
    use std::process::{Output, Stdio};

    const PREVIEW: &str = r#"{"slug":"k7m2qz","title":"Pushed by mistake","patchsets":1,"threads":1,"comments":2,"other_comments":1,"other_authors":["erin"]}"#;

    fn home(server_url: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let cfg_dir = dir.path().join(".config").join("reviews");
        std::fs::create_dir_all(&cfg_dir).unwrap();
        std::fs::write(
            cfg_dir.join("config.toml"),
            format!("[default]\nserver_url = \"{server_url}\"\napi_token = \"tok\"\n"),
        )
        .unwrap();
        dir
    }

    fn delete(home: &std::path::Path, args: &[&str], stdin: &str) -> Output {
        let mut child = bin()
            .arg("delete")
            .args(args)
            .env("HOME", home)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("run reviews delete");
        child
            .stdin
            .take()
            .unwrap()
            .write_all(stdin.as_bytes())
            .unwrap();
        child.wait_with_output().unwrap()
    }

    #[test]
    fn typing_the_slug_deletes_after_the_warning() {
        let mut server = Server::new();
        let home = home(&server.url());
        let preview = server
            .mock("GET", "/api/v1/reviews/k7m2qz/deletion")
            .match_header("authorization", "Bearer tok")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(PREVIEW)
            .create();
        let delete_mock = server
            .mock("DELETE", "/api/v1/reviews/k7m2qz")
            .match_header("authorization", "Bearer tok")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"slug":"k7m2qz","deleted":true}"#)
            .create();

        let out = delete(home.path(), &["k7m2qz"], "k7m2qz\n");

        assert!(out.status.success(), "{out:?}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains("1 comment by other people or agents will be deleted too (erin)"),
            "{stderr}"
        );
        assert!(String::from_utf8_lossy(&out.stdout).contains("Deleted review k7m2qz."));
        preview.assert();
        delete_mock.assert();
    }

    #[test]
    fn a_wrong_answer_sends_no_delete() {
        let mut server = Server::new();
        let home = home(&server.url());
        let _preview = server
            .mock("GET", "/api/v1/reviews/k7m2qz/deletion")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(PREVIEW)
            .create();
        let no_delete = server.mock("DELETE", Matcher::Any).expect(0).create();

        let out = delete(home.path(), &["k7m2qz"], "yes\n");

        assert!(!out.status.success(), "{out:?}");
        assert!(String::from_utf8_lossy(&out.stderr).contains("not deleted"));
        no_delete.assert();
    }

    #[test]
    fn yes_skips_the_prompt_and_a_refusal_is_explained() {
        let mut server = Server::new();
        let home = home(&server.url());
        let no_preview = server.mock("GET", Matcher::Any).expect(0).create();
        let refused = server
            .mock("DELETE", "/api/v1/reviews/k7m2qz")
            .with_status(403)
            .with_header("content-type", "application/json")
            .with_body(r#"{"errors":{"detail":"Only the review owner can delete it."},"error_code":"forbidden","error_detail":"Only the review owner can delete it."}"#)
            .create();

        let out = delete(home.path(), &["k7m2qz", "--yes"], "");

        assert!(!out.status.success(), "{out:?}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains("[forbidden]"), "{stderr}");
        assert!(stderr.contains("delete the review"), "{stderr}");
        no_preview.assert();
        refused.assert();
    }
}
