use anyhow::{Context, Result};
use std::io::{self, BufRead, Write};

use crate::api::ApiClient;
use crate::config::Config;

const DEFAULT_SERVER: &str = "https://reviews-dev.fly.dev";

pub fn run() -> Result<()> {
    let stdin = io::stdin();
    let mut stdin = stdin.lock();
    let mut stdout = io::stdout().lock();

    let server_url = prompt(
        &mut stdin,
        &mut stdout,
        &format!("Server URL [{DEFAULT_SERVER}]: "),
    )?;
    let server_url = if server_url.trim().is_empty() {
        DEFAULT_SERVER.to_string()
    } else {
        server_url.trim().to_string()
    };

    let api_token = prompt(
        &mut stdin,
        &mut stdout,
        "API token (mint one at <server>/settings): ",
    )?;
    let api_token = api_token.trim().to_string();
    if api_token.is_empty() {
        anyhow::bail!("API token is required");
    }

    // Verify before persisting so we don't write garbage.
    let client = ApiClient::new(&server_url, &api_token)?;
    let me = client
        .me()
        .context("could not verify token against server")?;

    let cfg = Config::new(server_url.clone(), api_token);
    let path = cfg.save()?;

    writeln!(
        stdout,
        "Logged in as {} ({}). Wrote config to {}.",
        me.username,
        server_url,
        path.display()
    )?;
    Ok(())
}

fn prompt<R: BufRead, W: Write>(stdin: &mut R, stdout: &mut W, msg: &str) -> Result<String> {
    write!(stdout, "{msg}")?;
    stdout.flush()?;
    let mut line = String::new();
    stdin.read_line(&mut line).context("could not read stdin")?;
    Ok(line)
}
