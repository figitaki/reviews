use anyhow::Result;
use clap::Args;

use crate::api::{ApiClient, UpdateThreadStatusRequest};
use crate::config::Config;

#[derive(Args, Debug)]
pub struct ThreadStatusArgs {
    /// Review slug (the `:slug` in `/r/:slug`).
    pub slug: String,

    /// Thread id from `reviews threads <slug>` or `reviews show`.
    pub thread_id: i64,
}

pub fn run(args: ThreadStatusArgs, status: &'static str) -> Result<()> {
    let cfg = Config::load()?;
    let client = ApiClient::new(&cfg.default.server_url, &cfg.default.api_token)?;
    let resp = client.update_thread_status(
        &args.slug,
        args.thread_id,
        &UpdateThreadStatusRequest { status },
    )?;

    println!("Thread #{} is now {}.", resp.id, resp.status);
    Ok(())
}
