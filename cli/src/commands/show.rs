use anyhow::{anyhow, Result};
use clap::{Args, ValueEnum};
use serde_json::Value;

use crate::api::ApiClient;
use crate::config::Config;

const DEFAULT_SERVER: &str = "https://reviews-dev.fly.dev";

#[derive(Args, Debug)]
pub struct ShowArgs {
    /// Review slug (the `:slug` in `/r/:slug`).
    pub slug: String,

    /// Patchset number to fetch. Defaults to the latest.
    #[arg(long)]
    pub patchset: Option<i64>,

    /// Output format.
    #[arg(long, value_enum, default_value_t = Format::Json)]
    pub format: Format,

    /// Override server URL. Defaults to the configured server, or
    /// https://reviews-dev.fly.dev if not logged in.
    #[arg(long)]
    pub server: Option<String>,
}

#[derive(Copy, Clone, Debug, ValueEnum)]
pub enum Format {
    Json,
    Md,
}

pub fn run(args: ShowArgs) -> Result<()> {
    let (server_url, token) = resolve_server_and_token(args.server.as_deref())?;
    let client = match token {
        Some(t) => ApiClient::new(server_url, t)?,
        None => ApiClient::anonymous(server_url)?,
    };
    let body = client.show_review(&args.slug, args.patchset)?;

    let out = match args.format {
        Format::Json => serde_json::to_string_pretty(&body)?,
        Format::Md => render_markdown(&body)?,
    };
    println!("{out}");
    Ok(())
}

fn resolve_server_and_token(server_override: Option<&str>) -> Result<(String, Option<String>)> {
    if let Some(s) = server_override {
        return Ok((s.to_string(), None));
    }
    match Config::load() {
        Ok(cfg) => Ok((cfg.default.server_url, Some(cfg.default.api_token))),
        Err(_) => Ok((DEFAULT_SERVER.to_string(), None)),
    }
}

fn render_markdown(body: &Value) -> Result<String> {
    let obj = body
        .as_object()
        .ok_or_else(|| anyhow!("response is not a JSON object"))?;

    let title = obj
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or("(untitled)");
    let url = obj.get("url").and_then(Value::as_str).unwrap_or("");
    let description = obj.get("description").and_then(Value::as_str).unwrap_or("");

    let mut out = String::new();
    out.push_str(&format!("# {title}\n\n"));
    if !url.is_empty() {
        out.push_str(&format!("{url}\n\n"));
    }
    if !description.is_empty() {
        out.push_str(&format!("{description}\n\n"));
    }

    if let Some(patchsets) = obj.get("patchsets").and_then(Value::as_array) {
        let nums: Vec<String> = patchsets
            .iter()
            .filter_map(|p| p.get("number").and_then(Value::as_i64))
            .map(|n| format!("v{n}"))
            .collect();
        if !nums.is_empty() {
            out.push_str(&format!("Patchsets: {}\n\n", nums.join(", ")));
        }
    }

    if let Some(selected) = obj.get("selected_patchset").and_then(Value::as_object) {
        let n = selected.get("number").and_then(Value::as_i64).unwrap_or(0);
        let branch = selected
            .get("branch_name")
            .and_then(Value::as_str)
            .unwrap_or("");
        let base = selected
            .get("base_sha")
            .and_then(Value::as_str)
            .unwrap_or("");
        out.push_str(&format!("## Patchset v{n}"));
        if !branch.is_empty() {
            out.push_str(&format!(" — `{branch}`"));
        }
        if !base.is_empty() {
            let short = if base.len() >= 12 { &base[..12] } else { base };
            out.push_str(&format!(" (base {short})"));
        }
        out.push_str("\n\n");

        if let Some(files) = selected.get("files").and_then(Value::as_array) {
            for file in files {
                let path = file.get("path").and_then(Value::as_str).unwrap_or("?");
                let status = file.get("status").and_then(Value::as_str).unwrap_or("?");
                let add = file.get("additions").and_then(Value::as_i64).unwrap_or(0);
                let del = file.get("deletions").and_then(Value::as_i64).unwrap_or(0);
                let status_letter = match status {
                    "added" => "A",
                    "modified" => "M",
                    "deleted" => "D",
                    "renamed" => "R",
                    _ => "?",
                };
                out.push_str(&format!("### {status_letter} `{path}` (+{add} -{del})\n\n"));
                let raw = file.get("raw_diff").and_then(Value::as_str).unwrap_or("");
                if !raw.is_empty() {
                    out.push_str("```diff\n");
                    out.push_str(raw);
                    if !raw.ends_with('\n') {
                        out.push('\n');
                    }
                    out.push_str("```\n\n");
                }
            }
        }
    }

    if let Some(threads) = obj.get("threads").and_then(Value::as_array) {
        if !threads.is_empty() {
            out.push_str("## Threads\n\n");
            for t in threads {
                let path = t.get("file_path").and_then(Value::as_str).unwrap_or("?");
                let line = t.get("line_hint").and_then(Value::as_i64);
                let author = t
                    .get("author")
                    .and_then(Value::as_str)
                    .unwrap_or("anonymous");
                let location = match line {
                    Some(n) => format!("{path}:{n}"),
                    None => path.to_string(),
                };
                out.push_str(&format!("### `{location}` — @{author}\n\n"));
                if let Some(comments) = t.get("comments").and_then(Value::as_array) {
                    for c in comments {
                        let body = c.get("body").and_then(Value::as_str).unwrap_or("");
                        for line in body.lines() {
                            out.push_str(&format!("> {line}\n"));
                        }
                        out.push('\n');
                    }
                }
            }
        }
    }

    Ok(out.trim_end().to_string() + "\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn markdown_renders_title_url_files_and_threads() {
        let body = json!({
            "slug": "k7m2qz",
            "title": "Add foo",
            "description": "A short description.",
            "url": "http://localhost:4000/r/k7m2qz",
            "patchsets": [{"number": 1}, {"number": 2}],
            "selected_patchset": {
                "number": 2,
                "branch_name": "carey/foo",
                "base_sha": "deadbeefcafe0000",
                "files": [{
                    "path": "foo",
                    "status": "modified",
                    "additions": 1,
                    "deletions": 1,
                    "raw_diff": "diff --git a/foo b/foo\n@@ -1 +1 @@\n-old\n+new\n"
                }]
            },
            "threads": [{
                "file_path": "foo",
                "line_hint": 1,
                "author": "carey",
                "comments": [{"body": "nit: rename?\nsee bug #42"}]
            }]
        });

        let md = render_markdown(&body).unwrap();
        assert!(md.contains("# Add foo"));
        assert!(md.contains("http://localhost:4000/r/k7m2qz"));
        assert!(md.contains("A short description."));
        assert!(md.contains("Patchsets: v1, v2"));
        assert!(md.contains("## Patchset v2 — `carey/foo` (base deadbeefcafe)"));
        assert!(md.contains("### M `foo` (+1 -1)"));
        assert!(md.contains("```diff"));
        assert!(md.contains("-old"));
        assert!(md.contains("+new"));
        assert!(md.contains("## Threads"));
        assert!(md.contains("### `foo:1` — @carey"));
        assert!(md.contains("> nit: rename?"));
        assert!(md.contains("> see bug #42"));
    }

    #[test]
    fn markdown_omits_threads_section_when_empty() {
        let body = json!({
            "title": "x",
            "url": "u",
            "patchsets": [],
            "selected_patchset": null,
            "threads": []
        });
        let md = render_markdown(&body).unwrap();
        assert!(!md.contains("## Threads"));
    }
}
