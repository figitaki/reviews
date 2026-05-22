use anyhow::{anyhow, Result};
use clap::Args;

use crate::api::{ApiClient, SectionDecisionRequest};
use crate::config::Config;

#[derive(Args, Debug)]
pub struct SectionArgs {
    /// Review slug (the `:slug` in `/r/:slug`).
    pub slug: String,

    /// Zero-based packet section index.
    pub section_index: i64,

    /// Decision to apply to the section.
    #[arg(value_parser = ["approved", "denied", "ignored"])]
    pub status: String,
}

pub fn run(args: SectionArgs) -> Result<()> {
    if args.section_index < 0 {
        return Err(anyhow!("section index must be >= 0"));
    }

    let cfg = Config::load()?;
    let client = ApiClient::new(&cfg.default.server_url, &cfg.default.api_token)?;
    let resp = client.set_section_decision(
        &args.slug,
        args.section_index,
        &SectionDecisionRequest {
            status: &args.status,
        },
    )?;

    let status = resp.status.as_deref().unwrap_or("pending");
    println!(
        "Section {} on {} marked {} in patchset {}.",
        resp.section_index, resp.review, status, resp.patchset_number
    );
    Ok(())
}
