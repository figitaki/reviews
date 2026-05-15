use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
enum Section {
    Invariants,
    Tour,
    Testing,
    Rollout,
    OpenQuestions,
}

#[derive(Debug, Clone)]
struct ParsedMarkdown {
    title: String,
    summary: String,
    sections: Vec<(Section, String)>,
}

pub fn load_packet(path: &Path) -> Result<Value> {
    let body = fs::read_to_string(path)
        .with_context(|| format!("could not read packet file {}", path.display()))?;

    match path.extension().and_then(|ext| ext.to_str()) {
        Some("json") => serde_json::from_str(&body)
            .with_context(|| format!("could not parse packet JSON {}", path.display())),
        Some("md") | Some("markdown") => parse_markdown(&body)
            .with_context(|| format!("could not parse packet Markdown {}", path.display())),
        Some(ext) => bail!("unsupported packet extension .{ext}; use .md or .json"),
        None => bail!("packet file must have a .md or .json extension"),
    }
}

pub fn discover_packet(repo: &Path, branch_name: &str) -> Option<PathBuf> {
    let dir = repo
        .join(".reviews")
        .join(sanitize_branch_name(branch_name));
    let md = dir.join("packet.md");
    if md.is_file() {
        return Some(md);
    }

    let json = dir.join("packet.json");
    json.is_file().then_some(json)
}

fn sanitize_branch_name(branch_name: &str) -> String {
    let mut out = String::new();
    for ch in branch_name.chars() {
        match ch {
            '/' | '\\' => out.push_str("__"),
            c if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') => out.push(c),
            _ => out.push('-'),
        }
    }
    if out.is_empty() {
        "HEAD".to_string()
    } else {
        out
    }
}

fn parse_markdown(body: &str) -> Result<Value> {
    let parsed = split_markdown(body)?;

    let mut packet = Map::new();
    packet.insert("format_version".to_string(), json!(1));
    packet.insert("title".to_string(), json!(parsed.title));

    if !parsed.summary.is_empty() {
        packet.insert("summary".to_string(), json!(parsed.summary));
    }

    for (section, content) in parsed.sections {
        match section {
            Section::Invariants => {
                let rows = parse_markdown_rows(&content);
                if !rows.is_empty() {
                    packet.insert("invariants".to_string(), Value::Array(rows));
                }
            }
            Section::Tour => {
                let rows = parse_tour_rows(&content);
                if !rows.is_empty() {
                    packet.insert("tour".to_string(), Value::Array(rows));
                }
            }
            Section::Testing => {
                let (instructions, tasks) = parse_testing(&content);
                if !instructions.is_empty() {
                    packet.insert("testing_instructions".to_string(), json!(instructions));
                }
                if !tasks.is_empty() {
                    packet.insert("tasks".to_string(), Value::Array(tasks));
                }
            }
            Section::Rollout => {
                let rows = parse_markdown_rows(&content);
                if !rows.is_empty() {
                    packet.insert("rollout".to_string(), Value::Array(rows));
                }
            }
            Section::OpenQuestions => {
                let questions = parse_open_questions(&content)?;
                if !questions.is_empty() {
                    packet.insert("open_questions".to_string(), Value::Array(questions));
                }
            }
        }
    }

    Ok(Value::Object(packet))
}

fn split_markdown(body: &str) -> Result<ParsedMarkdown> {
    let mut title = None;
    let mut summary_lines = Vec::new();
    let mut sections = Vec::new();
    let mut current_section: Option<Section> = None;
    let mut current_lines = Vec::new();

    for line in body.lines() {
        if let Some(rest) = line.strip_prefix("# ") {
            if title.is_some() {
                bail!("packet Markdown must contain exactly one top-level # title");
            }
            title = Some(rest.trim().to_string());
            continue;
        }

        if let Some(rest) = line.strip_prefix("## ") {
            if title.is_none() {
                bail!("packet Markdown must start with a # title before section headings");
            }

            if let Some(section) = current_section.take() {
                sections.push((section, trim_join(&current_lines)));
                current_lines.clear();
            }

            current_section = Some(parse_section(rest.trim())?);
            continue;
        }

        if title.is_none() {
            if line.trim().is_empty() {
                continue;
            }
            bail!("packet Markdown must start with a # title");
        }

        if current_section.is_some() {
            current_lines.push(line.to_string());
        } else {
            summary_lines.push(line.to_string());
        }
    }

    if let Some(section) = current_section {
        sections.push((section, trim_join(&current_lines)));
    }

    let title = title.ok_or_else(|| anyhow!("packet Markdown must start with a # title"))?;
    if title.is_empty() {
        bail!("packet title cannot be empty");
    }

    Ok(ParsedMarkdown {
        title,
        summary: trim_join(&summary_lines),
        sections,
    })
}

fn parse_section(heading: &str) -> Result<Section> {
    match heading {
        "Invariants" => Ok(Section::Invariants),
        "Tour" => Ok(Section::Tour),
        "Testing" => Ok(Section::Testing),
        "Rollout" => Ok(Section::Rollout),
        "Open Questions" => Ok(Section::OpenQuestions),
        other => bail!(
            "unknown packet section `## {other}`; expected Invariants, Tour, Testing, Rollout, or Open Questions"
        ),
    }
}

fn parse_markdown_rows(content: &str) -> Vec<Value> {
    content
        .split("\n\n")
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|body| json!({"kind": "markdown", "body": body}))
        .collect()
}

fn parse_tour_rows(content: &str) -> Vec<Value> {
    let mut rows = Vec::new();
    let mut prose = Vec::new();

    for line in content.lines() {
        if let Some(path) = line.trim().strip_prefix("@hunk ") {
            let body = trim_join(&prose);
            if !body.is_empty() {
                rows.push(json!({"kind": "markdown", "body": body}));
                prose.clear();
            }

            let path = path.trim();
            if !path.is_empty() {
                rows.push(json!({"kind": "hunk", "path": path}));
            }
        } else {
            prose.push(line.to_string());
        }
    }

    let body = trim_join(&prose);
    if !body.is_empty() {
        rows.push(json!({"kind": "markdown", "body": body}));
    }

    rows
}

fn parse_testing(content: &str) -> (String, Vec<Value>) {
    let mut instructions = Vec::new();
    let mut tasks = Vec::new();

    for line in content.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed
            .strip_prefix("- [ ] ")
            .or_else(|| trimmed.strip_prefix("- [x] "))
            .or_else(|| trimmed.strip_prefix("- [X] "))
        {
            let (key, description) = parse_optional_key(rest);
            let description = description.trim();
            if !description.is_empty() {
                tasks.push(json!({
                    "key": key.unwrap_or_else(|| slugify(description)),
                    "description": description
                }));
            }
        } else {
            instructions.push(line.to_string());
        }
    }

    (trim_join(&instructions), tasks)
}

fn parse_open_questions(content: &str) -> Result<Vec<Value>> {
    let mut questions = Vec::new();

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let rest = trimmed
            .strip_prefix("- ")
            .ok_or_else(|| anyhow!("open questions must use `- [key] Question text` list items"))?;
        let (key, body) = parse_required_key(rest)?;
        questions.push(json!({"key": key, "body": body.trim()}));
    }

    Ok(questions)
}

fn parse_optional_key(rest: &str) -> (Option<String>, &str) {
    match parse_bracketed_key(rest) {
        Some((key, body)) => (Some(key), body),
        None => (None, rest),
    }
}

fn parse_required_key(rest: &str) -> Result<(String, &str)> {
    parse_bracketed_key(rest)
        .ok_or_else(|| anyhow!("open questions must use `- [key] Question text` list items"))
}

fn parse_bracketed_key(rest: &str) -> Option<(String, &str)> {
    let rest = rest.strip_prefix('[')?;
    let end = rest.find(']')?;
    let key = rest[..end].trim();
    if key.is_empty() {
        return None;
    }
    Some((key.to_string(), rest[end + 1..].trim_start()))
}

fn trim_join(lines: &[String]) -> String {
    lines.join("\n").trim().to_string()
}

fn slugify(input: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;

    for ch in input.chars().flat_map(char::to_lowercase) {
        if ch.is_ascii_alphanumeric() {
            out.push(ch);
            last_dash = false;
        } else if !last_dash {
            out.push('-');
            last_dash = true;
        }
    }

    let out = out.trim_matches('-').to_string();
    if out.is_empty() {
        "task".to_string()
    } else {
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    const SAMPLE: &str = r#"# Invalidate search cache on document delete

Closes LIN-4892. Cache misses now follow the existing delete transaction.

## Invariants
- Cache is invalidated whenever a document is deleted.
- Existing search results still paginate the same way.

## Tour
### Add invalidate call
Hooks into the delete transaction.

@hunk lib/documents.ex

### Regression test
Covers the stale search result case.

@hunk test/search_cache_invalidation_test.exs

## Testing
Run the focused cache invalidation test.

- [ ] Delete a document via the UI and confirm it disappears from search.
- [ ] [focused-cache-test] Run `mix test test/search_cache_invalidation_test.exs`

## Rollout
Ship normally. No migration or feature flag.

## Open Questions
- [cache-backfill-window] Should we clear cache entries for documents deleted before this fix?
"#;

    #[test]
    fn parses_structured_markdown_packet() {
        let packet = parse_markdown(SAMPLE).unwrap();

        assert_eq!(packet["format_version"], 1);
        assert_eq!(
            packet["title"],
            "Invalidate search cache on document delete"
        );
        assert_eq!(
            packet["summary"],
            "Closes LIN-4892. Cache misses now follow the existing delete transaction."
        );
        assert_eq!(packet["invariants"].as_array().unwrap().len(), 1);

        let tour = packet["tour"].as_array().unwrap();
        assert_eq!(tour.len(), 4);
        assert_eq!(tour[0]["kind"], "markdown");
        assert!(tour[0]["body"]
            .as_str()
            .unwrap()
            .contains("### Add invalidate call"));
        assert_eq!(tour[1], json!({"kind": "hunk", "path": "lib/documents.ex"}));

        let tasks = packet["tasks"].as_array().unwrap();
        assert_eq!(
            tasks[0],
            json!({
                "key": "delete-a-document-via-the-ui-and-confirm-it-disappears-from-search",
                "description": "Delete a document via the UI and confirm it disappears from search."
            })
        );
        assert_eq!(tasks[1]["key"], "focused-cache-test");

        assert_eq!(
            packet["open_questions"][0],
            json!({
                "key": "cache-backfill-window",
                "body": "Should we clear cache entries for documents deleted before this fix?"
            })
        );
    }

    #[test]
    fn rejects_missing_title() {
        let err = parse_markdown("## Tour\nbody").unwrap_err();
        assert!(format!("{err:#}").contains("# title"));
    }

    #[test]
    fn rejects_unknown_sections() {
        let err = parse_markdown("# T\n\n## Security\nbody").unwrap_err();
        assert!(format!("{err:#}").contains("unknown packet section"));
    }

    #[test]
    fn rejects_open_questions_without_keys() {
        let err = parse_markdown("# T\n\n## Open Questions\n- Missing key?").unwrap_err();
        assert!(format!("{err:#}").contains("[key]"));
    }

    #[test]
    fn loads_json_packets_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("packet.json");
        fs::write(&path, r#"{"format_version":1,"title":"JSON"}"#).unwrap();

        let packet = load_packet(&path).unwrap();
        assert_eq!(packet["title"], "JSON");
    }

    #[test]
    fn discovers_markdown_before_json() {
        let dir = tempfile::tempdir().unwrap();
        let packet_dir = dir.path().join(".reviews").join("carey__packet-prototype");
        fs::create_dir_all(&packet_dir).unwrap();
        fs::write(packet_dir.join("packet.json"), "{}").unwrap();
        fs::write(packet_dir.join("packet.md"), "# T").unwrap();

        let found = discover_packet(dir.path(), "carey/packet-prototype").unwrap();
        assert_eq!(
            found.file_name().and_then(|n| n.to_str()),
            Some("packet.md")
        );
    }
}
