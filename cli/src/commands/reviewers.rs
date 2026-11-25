use anyhow::{anyhow, Result};
use clap::{Args, Subcommand};

use crate::api::{ApiClient, ReviewersResponse};
use crate::auth;
use crate::config::Config;

#[derive(Args, Debug)]
#[command(args_conflicts_with_subcommands = true)]
pub struct ReviewersArgs {
    #[command(subcommand)]
    pub action: Option<ReviewersAction>,

    /// Review slug, to list its reviewers.
    pub slug: Option<String>,
}

#[derive(Subcommand, Debug)]
pub enum ReviewersAction {
    /// Add reviewers by GitHub login. They can then decide sections. Owner only.
    Add {
        /// Review slug (the `:slug` in `/r/:slug`).
        slug: String,
        /// GitHub logins, with or without a leading `@`.
        #[arg(required = true)]
        logins: Vec<String>,
    },
    /// Remove reviewers. Their earlier decisions stay. Owner only.
    Remove {
        /// Review slug (the `:slug` in `/r/:slug`).
        slug: String,
        /// GitHub logins, with or without a leading `@`.
        #[arg(required = true)]
        logins: Vec<String>,
    },
}

pub fn run(args: ReviewersArgs) -> Result<()> {
    let cfg = Config::load()?;
    let client = auth::client(&cfg)?;

    let resp = match args.action {
        Some(ReviewersAction::Add { slug, logins }) => change(&client, &slug, &logins, true)?,
        Some(ReviewersAction::Remove { slug, logins }) => change(&client, &slug, &logins, false)?,
        None => {
            let slug = args
                .slug
                .ok_or_else(|| anyhow!("give a review slug, or `add`/`remove` with logins"))?;
            client.list_reviewers(&slug)?
        }
    };

    println!("{}", format_reviewers(&resp));
    Ok(())
}

/// Adds or removes each login in turn; `reviews push --reviewer` uses it too.
pub fn change(
    client: &ApiClient,
    slug: &str,
    logins: &[String],
    add: bool,
) -> Result<ReviewersResponse> {
    let mut last = None;
    for login in logins {
        let login = login.trim().trim_start_matches('@');
        last = Some(client.change_reviewer(slug, login, add)?);
    }
    last.ok_or_else(|| anyhow!("give at least one GitHub login"))
}

pub fn format_reviewers(resp: &ReviewersResponse) -> String {
    if resp.reviewers.is_empty() {
        return format!("{} has no reviewers.", resp.review);
    }

    let names: Vec<String> = resp
        .reviewers
        .iter()
        .map(|r| match r.status.as_str() {
            "invited" => format!("@{} (invited)", r.login),
            _ => format!("@{}", r.login),
        })
        .collect();

    format!("Reviewers of {}: {}", resp.review, names.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::Reviewer;

    #[test]
    fn marks_invited_reviewers() {
        let resp = ReviewersResponse {
            review: "k7m2qz".to_string(),
            reviewers: vec![
                Reviewer {
                    login: "sam".to_string(),
                    status: "active".to_string(),
                },
                Reviewer {
                    login: "riley".to_string(),
                    status: "invited".to_string(),
                },
            ],
        };

        assert_eq!(
            format_reviewers(&resp),
            "Reviewers of k7m2qz: @sam, @riley (invited)"
        );
    }

    #[test]
    fn adds_each_login_without_its_at_sign() {
        let mut server = mockito::Server::new();
        let body = r#"{"review":"k7m2qz","reviewers":[{"login":"sam","status":"active"},{"login":"riley","status":"invited"}]}"#;
        let sam = server
            .mock("PUT", "/api/v1/reviews/k7m2qz/reviewers/sam")
            .with_status(200)
            .with_body(body)
            .create();
        let riley = server
            .mock("PUT", "/api/v1/reviews/k7m2qz/reviewers/riley")
            .with_status(200)
            .with_body(body)
            .create();

        let client = ApiClient::new(server.url(), "tok").unwrap();
        let resp = change(
            &client,
            "k7m2qz",
            &["@sam".to_string(), "riley".to_string()],
            true,
        )
        .unwrap();

        sam.assert();
        riley.assert();
        assert_eq!(resp.reviewers.len(), 2);
    }
}
