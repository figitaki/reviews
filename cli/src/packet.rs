use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
struct ParsedMarkdown {
    title: String,
    summary: String,
    sections: Vec<ParsedSection>,
}

#[derive(Debug, Clone)]
struct ParsedSection {
    title: String,
    content: String,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct ChangeLine {
    path: String,
    hunk_index: usize,
    row: usize,
}

#[derive(Debug, Clone)]
struct DiffHunk {
    changed_rows: BTreeSet<usize>,
    row_count: usize,
}

type DiffIndex = BTreeMap<String, Vec<DiffHunk>>;

pub fn load_packet_for_diff(path: &Path, raw_diff: &str) -> Result<Value> {
    let body = fs::read_to_string(path)
        .with_context(|| format!("could not read packet file {}", path.display()))?;
    let diff = diff_index(raw_diff);

    let packet = match path.extension().and_then(|ext| ext.to_str()) {
        Some("json") => serde_json::from_str(&body)
            .with_context(|| format!("could not parse packet JSON {}", path.display()))?,
        Some("md") | Some("markdown") => parse_markdown(&body)
            .with_context(|| format!("could not parse packet Markdown {}", path.display()))?,
        Some(ext) => bail!("unsupported packet extension .{ext}; use .md or .json"),
        None => bail!("packet file must have a .md or .json extension"),
    };

    validate_packet(&packet, &diff)
        .with_context(|| format!("could not validate packet {}", path.display()))?;
    Ok(packet)
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

    let sections: Vec<Value> = parsed
        .sections
        .into_iter()
        .map(|section| {
            let rows = parse_section_rows(&section.content)?;
            Ok(json!({
                "title": section.title,
                "rows": rows
            }))
        })
        .collect::<Result<_>>()?;

    packet.insert("sections".to_string(), Value::Array(sections));
    Ok(Value::Object(packet))
}

fn split_markdown(body: &str) -> Result<ParsedMarkdown> {
    let mut title = None;
    let mut summary_lines = Vec::new();
    let mut sections = Vec::new();
    let mut current_title: Option<String> = None;
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

            if let Some(section_title) = current_title.take() {
                sections.push(ParsedSection {
                    title: section_title,
                    content: trim_join(&current_lines),
                });
                current_lines.clear();
            }

            let section_title = rest.trim();
            if section_title.is_empty() {
                bail!("packet section headings cannot be empty");
            }
            current_title = Some(section_title.to_string());
            continue;
        }

        if title.is_none() {
            if line.trim().is_empty() {
                continue;
            }
            bail!("packet Markdown must start with a # title");
        }

        if current_title.is_some() {
            current_lines.push(line.to_string());
        } else {
            summary_lines.push(line.to_string());
        }
    }

    if let Some(section_title) = current_title {
        sections.push(ParsedSection {
            title: section_title,
            content: trim_join(&current_lines),
        });
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

fn parse_section_rows(content: &str) -> Result<Vec<Value>> {
    let mut rows = Vec::new();
    let mut prose = Vec::new();

    for line in content.lines() {
        if let Some(rest) = line.trim().strip_prefix("@hunk ") {
            let body = trim_join(&prose);
            if !body.is_empty() {
                rows.push(json!({"kind": "markdown", "body": body}));
                prose.clear();
            }

            rows.push(parse_hunk_row(rest.trim())?);
        } else {
            prose.push(line.to_string());
        }
    }

    let body = trim_join(&prose);
    if !body.is_empty() {
        rows.push(json!({"kind": "markdown", "body": body}));
    }

    Ok(rows)
}

fn parse_hunk_row(rest: &str) -> Result<Value> {
    let (path_and_hunk, slice) = match rest.split_once(":L") {
        Some((left, right)) => (left, Some(right)),
        None => (rest, None),
    };

    let (path, hunk) = path_and_hunk.rsplit_once('#').ok_or_else(|| {
        anyhow!("hunk refs must look like `@hunk path#N` or `@hunk path#N:Lx-Ly`")
    })?;
    let path = path.trim();
    if path.is_empty() {
        bail!("hunk refs must include a path");
    }

    let hunk_index = parse_positive_usize(hunk.trim(), "hunk number")?;
    let mut row = Map::new();
    row.insert("kind".to_string(), json!("hunk"));
    row.insert("path".to_string(), json!(path));
    row.insert("hunk_index".to_string(), json!(hunk_index));

    if let Some(slice) = slice {
        let (start, end) = slice
            .split_once("-L")
            .ok_or_else(|| anyhow!("hunk slices must look like `Lx-Ly`"))?;
        let start = parse_positive_usize(start.trim(), "slice start")?;
        let end = parse_positive_usize(end.trim(), "slice end")?;
        if start > end {
            bail!("hunk slice start must be <= end");
        }
        row.insert("line_start".to_string(), json!(start));
        row.insert("line_end".to_string(), json!(end));
    }

    Ok(Value::Object(row))
}

fn parse_positive_usize(input: &str, label: &str) -> Result<usize> {
    let value: usize = input
        .parse()
        .with_context(|| format!("{label} must be a positive integer"))?;
    if value == 0 {
        bail!("{label} must be >= 1");
    }
    Ok(value)
}

fn validate_packet(packet: &Value, diff: &DiffIndex) -> Result<()> {
    validate_shape(packet)?;

    if diff.is_empty() {
        return Ok(());
    }

    let expected = expected_change_lines(diff);
    if expected.is_empty() {
        return Ok(());
    }

    let mut covered = BTreeMap::<ChangeLine, usize>::new();

    for row in packet_hunk_rows(packet) {
        let path = string_field(row, "path")?;
        let hunk_index = usize_field(row, "hunk_index")?;
        let hunks = diff
            .get(path)
            .ok_or_else(|| anyhow!("packet references unknown file `{path}`"))?;
        let hunk = hunks
            .get(hunk_index - 1)
            .ok_or_else(|| anyhow!("packet references unknown hunk `{path}#{hunk_index}`"))?;

        let (start, end) = match (
            optional_usize_field(row, "line_start")?,
            optional_usize_field(row, "line_end")?,
        ) {
            (Some(start), Some(end)) => (start, end),
            (None, None) => (1, hunk.row_count),
            _ => bail!("hunk rows must include both line_start and line_end or neither"),
        };

        if start == 0 || end == 0 || start > end || end > hunk.row_count {
            bail!(
                "packet references invalid slice `{path}#{hunk_index}:L{start}-L{end}`; hunk has {} rows",
                hunk.row_count
            );
        }

        for row_number in hunk.changed_rows.range(start..=end) {
            let key = ChangeLine {
                path: path.to_string(),
                hunk_index,
                row: *row_number,
            };
            *covered.entry(key).or_insert(0) += 1;
        }
    }

    let covered_lines: BTreeSet<_> = covered.keys().cloned().collect();
    let missing: Vec<_> = expected.difference(&covered_lines).collect();
    if let Some(line) = missing.first() {
        bail!(
            "packet does not cover changed line `{}`#{}:L{}",
            line.path,
            line.hunk_index,
            line.row
        );
    }

    if let Some((line, count)) = covered.iter().find(|(_, count)| **count > 1) {
        bail!(
            "packet covers changed line `{}`#{}:L{} more than once ({count} times)",
            line.path,
            line.hunk_index,
            line.row
        );
    }

    Ok(())
}

fn validate_shape(packet: &Value) -> Result<()> {
    let obj = packet
        .as_object()
        .ok_or_else(|| anyhow!("packet must be a JSON object"))?;

    match obj.get("title").and_then(Value::as_str).map(str::trim) {
        Some(title) if !title.is_empty() => {}
        _ => bail!("packet title cannot be empty"),
    }

    let sections = obj
        .get("sections")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("packet must include a sections array"))?;

    for (section_idx, section) in sections.iter().enumerate() {
        let section = section
            .as_object()
            .ok_or_else(|| anyhow!("packet section {} must be an object", section_idx + 1))?;
        match section.get("title").and_then(Value::as_str).map(str::trim) {
            Some(title) if !title.is_empty() => {}
            _ => bail!("packet section {} must include a title", section_idx + 1),
        }
        let rows = section
            .get("rows")
            .and_then(Value::as_array)
            .ok_or_else(|| {
                anyhow!(
                    "packet section {} must include a rows array",
                    section_idx + 1
                )
            })?;
        for (row_idx, row) in rows.iter().enumerate() {
            let kind = row.get("kind").and_then(Value::as_str).ok_or_else(|| {
                anyhow!(
                    "packet section {} row {} must include kind",
                    section_idx + 1,
                    row_idx + 1
                )
            })?;
            match kind {
                "markdown" => {
                    if row.get("body").and_then(Value::as_str).is_none() {
                        bail!("markdown row must include body");
                    }
                }
                "hunk" => {
                    string_field(row, "path")?;
                    usize_field(row, "hunk_index")?;
                }
                other => bail!("unknown packet row kind `{other}`"),
            }
        }
    }

    Ok(())
}

fn packet_hunk_rows(packet: &Value) -> Vec<&Value> {
    packet
        .get("sections")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|section| {
            section
                .get("rows")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .filter(|row| row.get("kind").and_then(Value::as_str) == Some("hunk"))
        .collect()
}

fn string_field<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("hunk rows must include `{key}`"))
}

fn usize_field(value: &Value, key: &str) -> Result<usize> {
    value
        .get(key)
        .and_then(Value::as_u64)
        .map(|value| value as usize)
        .filter(|value| *value > 0)
        .ok_or_else(|| anyhow!("hunk rows must include positive integer `{key}`"))
}

fn optional_usize_field(value: &Value, key: &str) -> Result<Option<usize>> {
    match value.get(key) {
        Some(v) => v
            .as_u64()
            .map(|value| Some(value as usize))
            .ok_or_else(|| anyhow!("`{key}` must be a positive integer")),
        None => Ok(None),
    }
}

fn expected_change_lines(diff: &DiffIndex) -> BTreeSet<ChangeLine> {
    let mut expected = BTreeSet::new();
    for (path, hunks) in diff {
        for (idx, hunk) in hunks.iter().enumerate() {
            for row in &hunk.changed_rows {
                expected.insert(ChangeLine {
                    path: path.clone(),
                    hunk_index: idx + 1,
                    row: *row,
                });
            }
        }
    }
    expected
}

fn diff_index(raw_diff: &str) -> DiffIndex {
    let mut index = DiffIndex::new();
    for chunk in raw_diff.split("\ndiff --git ") {
        let chunk = chunk.strip_prefix("diff --git ").unwrap_or(chunk);
        let mut lines = chunk.lines();
        let Some(header) = lines.next() else { continue };
        let Some(path) = path_from_header(header, chunk) else {
            continue;
        };
        let mut hunks = Vec::new();
        let mut current: Option<DiffHunk> = None;

        for line in lines {
            if line.starts_with("@@ ") {
                if let Some(hunk) = current.take() {
                    hunks.push(hunk);
                }
                current = Some(DiffHunk {
                    changed_rows: BTreeSet::new(),
                    row_count: 0,
                });
                continue;
            }

            if let Some(hunk) = current.as_mut() {
                if line.starts_with('\\') {
                    continue;
                }
                hunk.row_count += 1;
                if (line.starts_with('+') && !line.starts_with("+++"))
                    || (line.starts_with('-') && !line.starts_with("---"))
                {
                    hunk.changed_rows.insert(hunk.row_count);
                }
            }
        }

        if let Some(hunk) = current {
            hunks.push(hunk);
        }
        if !hunks.is_empty() {
            index.insert(path, hunks);
        }
    }
    index
}

fn path_from_header(header: &str, chunk: &str) -> Option<String> {
    let (_, new_path) = header.strip_prefix("a/")?.split_once(" b/")?;
    if chunk.contains("\ndeleted file mode") {
        let (old_path, _) = header.strip_prefix("a/")?.split_once(" b/")?;
        Some(old_path.to_string())
    } else {
        Some(new_path.to_string())
    }
}

fn trim_join(lines: &[String]) -> String {
    lines.join("\n").trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    const DIFF: &str = "diff --git a/lib/a.ex b/lib/a.ex\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1,3 +1,3 @@\n context\n-old\n+new\n@@ -8,2 +8,3 @@\n other\n+added\n+again\n";

    const PACKET: &str = r#"# Narrative packet

Read this first.

## First section
This explains the first change.

@hunk lib/a.ex#1:L2-L3

Then the second hunk.

@hunk lib/a.ex#2
"#;

    #[test]
    fn parses_sections_with_interleaved_hunk_slices() {
        let packet = parse_markdown(PACKET).unwrap();

        assert_eq!(packet["format_version"], 1);
        assert_eq!(packet["title"], "Narrative packet");
        assert_eq!(packet["summary"], "Read this first.");
        let sections = packet["sections"].as_array().unwrap();
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0]["title"], "First section");
        let rows = sections[0]["rows"].as_array().unwrap();
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[1]["kind"], "hunk");
        assert_eq!(rows[1]["path"], "lib/a.ex");
        assert_eq!(rows[1]["hunk_index"], 1);
        assert_eq!(rows[1]["line_start"], 2);
        assert_eq!(rows[1]["line_end"], 3);
    }

    #[test]
    fn validates_full_changed_line_coverage() {
        let packet = parse_markdown(PACKET).unwrap();
        validate_packet(&packet, &diff_index(DIFF)).unwrap();
    }

    #[test]
    fn rejects_missing_changed_line_coverage() {
        let packet = parse_markdown("# T\n\n## S\n@hunk lib/a.ex#1:L2-L3").unwrap();
        let err = validate_packet(&packet, &diff_index(DIFF)).unwrap_err();
        assert!(format!("{err:#}").contains("does not cover changed line"));
    }

    #[test]
    fn rejects_duplicate_changed_line_coverage() {
        let packet = parse_markdown(
            "# T\n\n## S\n@hunk lib/a.ex#1\n@hunk lib/a.ex#1:L2-L3\n@hunk lib/a.ex#2",
        )
        .unwrap();
        let err = validate_packet(&packet, &diff_index(DIFF)).unwrap_err();
        assert!(format!("{err:#}").contains("more than once"));
    }

    #[test]
    fn rejects_unknown_hunk_refs() {
        let packet = parse_markdown("# T\n\n## S\n@hunk lib/a.ex#3").unwrap();
        let err = validate_packet(&packet, &diff_index(DIFF)).unwrap_err();
        assert!(format!("{err:#}").contains("unknown hunk"));
    }

    #[test]
    fn rejects_invalid_slice_ranges() {
        let packet = parse_markdown("# T\n\n## S\n@hunk lib/a.ex#1:L2-L8").unwrap();
        let err = validate_packet(&packet, &diff_index(DIFF)).unwrap_err();
        assert!(format!("{err:#}").contains("invalid slice"));
    }

    #[test]
    fn rejects_missing_title() {
        let err = parse_markdown("## Section\nbody").unwrap_err();
        assert!(format!("{err:#}").contains("# title"));
    }

    #[test]
    fn validates_json_packets() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("packet.json");
        fs::write(
            &path,
            r#"{"format_version":1,"title":"JSON","sections":[{"title":"S","rows":[{"kind":"hunk","path":"lib/a.ex","hunk_index":1},{"kind":"hunk","path":"lib/a.ex","hunk_index":2}]}]}"#,
        )
        .unwrap();

        let packet = load_packet_for_diff(&path, DIFF).unwrap();
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
