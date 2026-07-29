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

    println!("{}", decision_message(&resp));
    Ok(())
}

fn decision_message(resp: &crate::api::SectionDecisionResponse) -> String {
    match resp.status.as_deref() {
        Some(status) => format!(
            "Section {} on {} marked {} in patchset {}.",
            resp.section_index, resp.review, status, resp.patchset_number
        ),
        None => format!(
            "Section {} on {} cleared to pending in patchset {}.",
            resp.section_index, resp.review, resp.patchset_number
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::SectionDecisionResponse;

    #[test]
    fn formats_a_cleared_decision_as_pending() {
        let response = SectionDecisionResponse {
            review: "k7m2qz".to_string(),
            patchset_number: 2,
            section_index: 1,
            status: None,
        };

        assert_eq!(
            decision_message(&response),
            "Section 1 on k7m2qz cleared to pending in patchset 2."
        );
    }
}
