//! `reviews list`: the reviews you wrote or took part in.
//!
//! Calls `GET /api/v1/reviews` (see docs/CONTRACTS.md). Prints a table by
//! default, or the raw JSON response with `--json`.

use anyhow::{Context, Result};
use clap::{Args, ValueEnum};
use serde::Deserialize;
use serde_json::Value;

use crate::api::{ApiClient, ListReviewsQuery};
use crate::config::Config;

const TITLE_WIDTH: usize = 48;

#[derive(Args, Debug)]
pub struct ListArgs {
    /// Show only reviews you wrote, or only reviews you took part in.
    #[arg(long, value_enum, default_value_t = Role::All)]
    pub role: Role,

    /// Show only reviews with open threads, or with a patchset newer than
    /// your last comment, decision, or viewed hunk.
    #[arg(long, value_enum, default_value_t = Status::All)]
    pub status: Status,

    /// Show only reviews by this author handle (the `@` is optional).
    #[arg(long)]
    pub author: Option<String>,

    /// Find text in the title or slug.
    #[arg(long, short = 'q')]
    pub search: Option<String>,

    /// Number of reviews to show (1 to 100).
    #[arg(long, default_value_t = 25, value_parser = clap::value_parser!(u32).range(1..=100))]
    pub limit: u32,

    /// Number of reviews to skip, for the next page.
    #[arg(long, default_value_t = 0)]
    pub offset: u32,

    /// Print the server's JSON response instead of a table.
    #[arg(long)]
    pub json: bool,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, ValueEnum)]
pub enum Role {
    All,
    Authored,
    Involved,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, ValueEnum)]
pub enum Status {
    All,
    Open,
    Updated,
}

impl Role {
    fn as_param(self) -> Option<String> {
        match self {
            Role::All => None,
            Role::Authored => Some("authored".into()),
            Role::Involved => Some("involved".into()),
        }
    }
}

impl Status {
    fn as_param(self) -> Option<String> {
        match self {
            Status::All => None,
            Status::Open => Some("open".into()),
            Status::Updated => Some("updated".into()),
        }
    }
}

#[derive(Debug, Deserialize)]
struct ReviewList {
    reviews: Vec<ReviewRow>,
    next_offset: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct ReviewRow {
    slug: String,
    title: String,
    author: Option<Author>,
    patchset_count: i64,
    thread_count: i64,
    open_thread_count: i64,
    updated_at: Option<String>,
    has_new_patchset: bool,
}

#[derive(Debug, Deserialize)]
struct Author {
    handle: String,
    kind: String,
}

pub fn run(args: ListArgs) -> Result<()> {
    let cfg = Config::load()?;
    let client = ApiClient::new(&cfg.default.server_url, &cfg.default.api_token)?;
    let body = client.list_reviews(&query_for(&args))?;

    if args.json {
        println!("{}", serde_json::to_string_pretty(&body)?);
    } else {
        print!("{}", render_table(&body, &args)?);
    }
    Ok(())
}

fn query_for(args: &ListArgs) -> ListReviewsQuery {
    ListReviewsQuery {
        role: args.role.as_param(),
        status: args.status.as_param(),
        author: args.author.clone().filter(|s| !s.trim().is_empty()),
        q: args.search.clone().filter(|s| !s.trim().is_empty()),
        limit: Some(args.limit),
        offset: (args.offset > 0).then_some(args.offset),
    }
}

fn render_table(body: &Value, args: &ListArgs) -> Result<String> {
    let list: ReviewList = serde_json::from_value(body.clone())
        .context("could not read the review list in the server response")?;

    if list.reviews.is_empty() {
        return Ok("No reviews found.\n".to_string());
    }

    let rows: Vec<[String; 6]> = list
        .reviews
        .iter()
        .map(|r| {
            let author = match &r.author {
                Some(a) if a.kind == "agent" => format!("@{} (agent)", a.handle),
                Some(a) => format!("@{}", a.handle),
                None => "-".to_string(),
            };
            let threads = if r.open_thread_count > 0 {
                format!("{} ({} open)", r.thread_count, r.open_thread_count)
            } else {
                r.thread_count.to_string()
            };
            let patchsets = if r.has_new_patchset {
                format!("{} new", r.patchset_count)
            } else {
                r.patchset_count.to_string()
            };
            [
                r.slug.clone(),
                truncate(&r.title, TITLE_WIDTH),
                author,
                patchsets,
                threads,
                short_time(r.updated_at.as_deref()),
            ]
        })
        .collect();

    let header = [
        "SLUG",
        "TITLE",
        "AUTHOR",
        "PATCHSETS",
        "THREADS",
        "UPDATED (UTC)",
    ];
    let mut widths: Vec<usize> = header.iter().map(|h| h.chars().count()).collect();
    for row in &rows {
        for (i, cell) in row.iter().enumerate() {
            widths[i] = widths[i].max(cell.chars().count());
        }
    }

    let mut out = String::new();
    push_row(&mut out, header.iter().map(|h| h.to_string()), &widths);
    for row in rows {
        push_row(&mut out, row.into_iter(), &widths);
    }

    if let Some(next) = list.next_offset {
        out.push_str(&format!(
            "\nMore reviews exist. Run again with --offset {next}{}.\n",
            if args.limit != 25 {
                format!(" --limit {}", args.limit)
            } else {
                String::new()
            }
        ));
    }
    Ok(out)
}

fn push_row(out: &mut String, cells: impl Iterator<Item = String>, widths: &[usize]) {
    let cells: Vec<String> = cells.collect();
    let last = cells.len() - 1;
    let line: Vec<String> = cells
        .into_iter()
        .enumerate()
        .map(|(i, cell)| {
            if i == last {
                cell
            } else {
                let pad = widths[i] - cell.chars().count();
                format!("{cell}{}", " ".repeat(pad))
            }
        })
        .collect();
    out.push_str(line.join("  ").trim_end());
    out.push('\n');
}

fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        text.to_string()
    } else {
        let mut cut: String = text.chars().take(max - 1).collect();
        cut.push('…');
        cut
    }
}

/// `2026-10-09T15:04:05Z` -> `2026-10-09 15:04`. Other shapes print as is.
fn short_time(iso: Option<&str>) -> String {
    match iso {
        None => "-".to_string(),
        Some(s) if s.len() >= 16 && s.as_bytes()[10] == b'T' => {
            format!("{} {}", &s[..10], &s[11..16])
        }
        Some(s) => s.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;
    use serde_json::json;

    #[derive(Parser)]
    struct TestCli {
        #[command(flatten)]
        args: ListArgs,
    }

    fn parse(argv: &[&str]) -> ListArgs {
        let mut full = vec!["reviews-list"];
        full.extend_from_slice(argv);
        TestCli::try_parse_from(full).unwrap().args
    }

    fn sample() -> Value {
        json!({
            "reviews": [
                {
                    "slug": "k7m2qz",
                    "title": "Make user lookup faster",
                    "url": "http://localhost:4000/r/k7m2qz",
                    "author": {"handle": "conner", "kind": "human"},
                    "role": "involved",
                    "patchset_count": 2,
                    "thread_count": 3,
                    "open_thread_count": 1,
                    "updated_at": "2026-10-09T15:04:05Z",
                    "has_new_patchset": true
                },
                {
                    "slug": "a1b2c3d4",
                    "title": "Agent cleanup of many unused helpers across the codebase and tests",
                    "author": {"handle": "codex", "kind": "agent"},
                    "role": "authored",
                    "patchset_count": 1,
                    "thread_count": 0,
                    "open_thread_count": 0,
                    "updated_at": "2026-10-08T09:00:00Z",
                    "has_new_patchset": false
                }
            ],
            "limit": 2,
            "offset": 0,
            "next_offset": 2
        })
    }

    #[test]
    fn default_args_send_only_limit() {
        let q = query_for(&parse(&[]));
        assert_eq!(q.role, None);
        assert_eq!(q.status, None);
        assert_eq!(q.author, None);
        assert_eq!(q.q, None);
        assert_eq!(q.limit, Some(25));
        assert_eq!(q.offset, None);
    }

    #[test]
    fn flags_map_to_query_params() {
        let q = query_for(&parse(&[
            "--role", "involved", "--status", "updated", "--author", "@conner", "-q", "billing",
            "--limit", "5", "--offset", "10",
        ]));
        assert_eq!(q.role.as_deref(), Some("involved"));
        assert_eq!(q.status.as_deref(), Some("updated"));
        assert_eq!(q.author.as_deref(), Some("@conner"));
        assert_eq!(q.q.as_deref(), Some("billing"));
        assert_eq!(q.limit, Some(5));
        assert_eq!(q.offset, Some(10));
    }

    #[test]
    fn limit_out_of_range_is_rejected() {
        let mut full = vec!["reviews-list", "--limit", "500"];
        assert!(TestCli::try_parse_from(&full).is_err());
        full[2] = "0";
        assert!(TestCli::try_parse_from(&full).is_err());
    }

    #[test]
    fn table_has_header_rows_and_next_page_hint() {
        let out = render_table(&sample(), &parse(&["--limit", "2"])).unwrap();
        let lines: Vec<&str> = out.lines().collect();

        assert!(lines[0].starts_with("SLUG"));
        assert!(lines[0].contains("UPDATED (UTC)"));
        assert!(lines[1].starts_with("k7m2qz"));
        assert!(lines[1].contains("Make user lookup faster"));
        assert!(lines[1].contains("@conner"));
        assert!(lines[1].contains("2 new"));
        assert!(lines[1].contains("3 (1 open)"));
        assert!(lines[1].ends_with("2026-10-09 15:04"));
        assert!(lines[2].contains("@codex (agent)"));
        assert!(lines[2].contains("Agent cleanup of many unused helpers across the…"));
        assert!(out.contains("Run again with --offset 2 --limit 2."));

        // Columns line up: the TITLE column starts at the same place on each row.
        let title_col = lines[0].find("TITLE").unwrap();
        assert_eq!(&lines[1][title_col..title_col + 4], "Make");
    }

    #[test]
    fn empty_list_says_so() {
        let body = json!({"reviews": [], "limit": 25, "offset": 0, "next_offset": null});
        assert_eq!(
            render_table(&body, &parse(&[])).unwrap(),
            "No reviews found.\n"
        );
    }

    #[test]
    fn short_time_handles_odd_input() {
        assert_eq!(short_time(None), "-");
        assert_eq!(short_time(Some("yesterday")), "yesterday");
    }
}
