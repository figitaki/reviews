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
