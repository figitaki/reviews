use anyhow::{bail, Context, Result};
use clap::Args;
use std::io::{self, BufRead, Write};

use crate::api::ApiClient;
use crate::auth;
use crate::config::Config;

const DEFAULT_SERVER: &str = "https://reviews.figitaki.dev";

#[derive(Args, Debug)]
pub struct LoginArgs {
    /// Reviews server URL. Defaults to the server you last logged in to, or
    /// https://reviews.figitaki.dev.
    #[arg(long, value_name = "URL")]
    pub server: Option<String>,

    /// Paste an API token minted at <server>/settings instead of signing in
    /// from the browser. Reads it from stdin, so `reviews login --token <
    /// file` works in scripts.
    #[arg(long)]
    pub token: bool,
}

pub fn run(args: LoginArgs) -> Result<()> {
    let server_url = args
        .server
        .or_else(|| Config::load().ok().map(|cfg| cfg.default.server_url))
        .unwrap_or_else(|| DEFAULT_SERVER.to_string())
        .trim_end_matches('/')
        .to_string();

    let cfg = if args.token {
        token_login(&server_url)?
    } else {
        device_login(&server_url)?
    };

    // Verify before persisting so we don't write garbage.
    let token = match &cfg.default.oauth {
        Some(oauth) => oauth.access_token.clone(),
        None => cfg.default.api_token.clone().unwrap_or_default(),
    };
    let client = ApiClient::new(&server_url, token)?;
    let me = client
        .me()
        .context("could not verify the sign-in with the server")?;
    let path = cfg.save()?;

    println!(
        "Logged in as {} ({}). Wrote config to {}.",
        me.username,
        server_url,
        path.display()
    );
    Ok(())
}

/// The device authorization grant: show a code, wait for the browser.
fn device_login(server_url: &str) -> Result<Config> {
    let http = auth::http()?;
    let endpoints = auth::discover(&http, server_url)?;
    let device = auth::start(&http, server_url, &endpoints)?;

    eprintln!("To sign in, open this page on any device:\n");
    eprintln!("  {}\n", device.verification_uri);
    eprintln!("and enter the code:\n");
    eprintln!("  {}\n", device.user_code);
    if let Some(complete) = &device.verification_uri_complete {
        eprintln!("Or open {complete}, and check the code matches.\n");
    }
    eprintln!(
        "Waiting for you to allow it (the code expires in {} minutes; Ctrl-C to cancel)...",
        device.expires_in / 60
    );

    let tokens = auth::poll(
        &http,
        &endpoints,
        &device,
        &mut std::thread::sleep,
        &auth::now,
    )?;
    Ok(Config::with_oauth(server_url.to_string(), tokens))
}

/// The fallback: an API token minted in Settings.
fn token_login(server_url: &str) -> Result<Config> {
    let stdin = io::stdin();
    let mut stdin = stdin.lock();
    let mut stderr = io::stderr().lock();

    write!(stderr, "API token (mint one at {server_url}/settings): ")?;
    stderr.flush()?;
    let mut line = String::new();
    stdin.read_line(&mut line).context("could not read stdin")?;
    let api_token = line.trim().to_string();
    if api_token.is_empty() {
        bail!("API token is required");
    }
    Ok(Config::new(server_url.to_string(), api_token))
}
