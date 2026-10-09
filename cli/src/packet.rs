use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

/// One problem found while checking a packet. `line` is the 1-based line in
/// the packet file, when the problem points at a specific line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Issue {
    pub line: Option<usize>,
    pub message: String,
}

impl Issue {
    fn at(line: Option<usize>, message: impl Into<String>) -> Self {
        Issue {
            line,
            message: message.into(),
        }
    }
}

/// The result of checking a packet file against a diff. `push` and
/// `push --dry-run` both build this; a real push refuses to send a packet that
/// has any issues.
#[derive(Debug, Clone)]
pub struct PacketCheck {
    pub path: PathBuf,
    /// The packet as it would be sent. `None` when the file could not be
    /// turned into a packet at all (for example, invalid JSON).
    pub packet: Option<Value>,
    pub issues: Vec<Issue>,
}

impl PacketCheck {
    pub fn is_valid(&self) -> bool {
        self.packet.is_some() && self.issues.is_empty()
    }

    /// Each issue as `path:line: message` (or `path: message` when the issue
    /// has no single line), using `display_path` for the path.
    pub fn issue_lines(&self, display_path: &str) -> Vec<String> {
        self.issues
            .iter()
            .map(|issue| match issue.line {
                Some(line) => format!("{display_path}:{line}: {}", issue.message),
                None => format!("{display_path}: {}", issue.message),
            })
            .collect()
    }

    /// The packet to send, or an error that lists every issue.
    pub fn into_packet(self) -> Result<Value> {
        if let (Some(packet), true) = (&self.packet, self.issues.is_empty()) {
            return Ok(packet.clone());
        }
        let display = self.path.display().to_string();
        let lines = self.issue_lines(&display);
        bail!(
            "packet {} has {}:\n  {}",
            display,
            plural(lines.len(), "problem"),
            lines.join("\n  ")
        )
    }
}

/// What a packet contains, for the dry-run report.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PacketSummary {
    pub title: String,
    pub sections: Vec<SectionSummary>,
    pub hunk_refs: usize,
    pub files: BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SectionSummary {
    pub title: String,
    pub hunk_refs: usize,
}

/// A file in the diff and how many hunks it has.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffFile {
    pub path: String,
    pub hunks: usize,
}

#[derive(Debug, Clone)]
struct ParsedMarkdown {
    title: Option<String>,
    title_line: Option<usize>,
    summary: String,
    sections: Vec<ParsedSection>,
}

#[derive(Debug, Clone)]
struct ParsedSection {
    title: String,
    line: usize,
    lines: Vec<(usize, String)>,
}

/// Maps packet sections and rows back to lines in the packet file. Empty for
/// JSON packets, whose issues name the section and row instead.
#[derive(Debug, Clone, Default)]
struct SourceMap {
    markdown: bool,
    title_line: Option<usize>,
    sections: Vec<SectionSource>,
}

#[derive(Debug, Clone, Default)]
struct SectionSource {
    line: usize,
    rows: Vec<usize>,
}

impl SourceMap {
    fn section_line(&self, section_idx: usize) -> Option<usize> {
        self.sections.get(section_idx).map(|s| s.line)
    }

    fn row_line(&self, section_idx: usize, row_idx: usize) -> Option<usize> {
        self.sections
            .get(section_idx)
            .and_then(|s| s.rows.get(row_idx).copied())
    }
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

/// Read, parse and check a packet, collecting every problem instead of
/// stopping at the first one. Returns `Err` only when the file cannot be read
/// or has an unsupported extension.
pub fn check_packet_for_diff(path: &Path, raw_diff: &str) -> Result<PacketCheck> {
    let body = fs::read_to_string(path)
        .with_context(|| format!("could not read packet file {}", path.display()))?;
    let diff = diff_index(raw_diff);

    let (packet, mut issues, source) = match path.extension().and_then(|ext| ext.to_str()) {
        Some("json") => match serde_json::from_str::<Value>(&body) {
            Ok(packet) => (Some(packet), Vec::new(), SourceMap::default()),
            Err(err) => (
                None,
                vec![Issue::at(
                    Some(err.line()),
                    format!("packet is not valid JSON: {err}"),
                )],
                SourceMap::default(),
            ),
        },
        Some("md") | Some("markdown") => {
            let mut issues = Vec::new();
            let (packet, source) = parse_markdown_with_source(&body, &mut issues);
            (Some(packet), issues, source)
        }
        Some(ext) => bail!("unsupported packet extension .{ext}; use .md or .json"),
        None => bail!("packet file must have a .md or .json extension"),
    };

    if let Some(packet) = &packet {
        issues.extend(validate_packet(packet, &diff, &source));
    }
    issues.sort_by_key(|issue| issue.line.unwrap_or(usize::MAX));

    Ok(PacketCheck {
        path: path.to_path_buf(),
        packet,
        issues,
    })
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

/// Summarize a packet for display. Tolerates a packet with a bad shape; it
/// counts what it can read.
pub fn summarize(packet: &Value) -> PacketSummary {
    let title = packet
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let mut files = BTreeSet::new();
    let mut hunk_refs = 0;
    let sections = packet
        .get("sections")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|section| {
            let rows = section
                .get("rows")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|row| row.get("kind").and_then(Value::as_str) == Some("hunk"));
            let mut count = 0;
            for row in rows {
                count += 1;
                if let Some(path) = row.get("path").and_then(Value::as_str) {
                    files.insert(path.to_string());
                }
            }
            hunk_refs += count;
            SectionSummary {
                title: section
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
                hunk_refs: count,
            }
        })
        .collect();

    PacketSummary {
        title,
        sections,
        hunk_refs,
        files,
    }
}

/// The files in a raw diff and how many hunks each has, in path order.
pub fn diff_files(raw_diff: &str) -> Vec<DiffFile> {
    diff_index(raw_diff)
        .into_iter()
        .map(|(path, hunks)| DiffFile {
            path,
            hunks: hunks.len(),
        })
        .collect()
}

pub fn plural(count: usize, noun: &str) -> String {
    if count == 1 {
        format!("1 {noun}")
    } else {
        format!("{count} {noun}s")
    }
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

/// Parse packet Markdown, failing on the first problem. Used by tests that
/// only care about the parsed shape.
#[cfg(test)]
fn parse_markdown(body: &str) -> Result<Value> {
    let mut issues = Vec::new();
    let (packet, source) = parse_markdown_with_source(body, &mut issues);
    issues.extend(validate_shape(&packet, &source));
    match issues.first() {
        Some(issue) => Err(anyhow!(issue.message.clone())),
        None => Ok(packet),
    }
}

fn parse_markdown_with_source(body: &str, issues: &mut Vec<Issue>) -> (Value, SourceMap) {
    let parsed = split_markdown(body, issues);
    let mut packet = Map::new();
    packet.insert("format_version".to_string(), json!(1));
    packet.insert(
        "title".to_string(),
        json!(parsed.title.clone().unwrap_or_default()),
    );

    if !parsed.summary.is_empty() {
        packet.insert("summary".to_string(), json!(parsed.summary));
    }

    let mut source = SourceMap {
        markdown: true,
        title_line: parsed.title_line,
        sections: Vec::new(),
    };

    let sections: Vec<Value> = parsed
        .sections
        .into_iter()
        .map(|section| {
            let (rows, row_lines) = parse_section_rows(&section.lines, issues);
            source.sections.push(SectionSource {
                line: section.line,
                rows: row_lines,
            });
            json!({
                "title": section.title,
                "rows": rows
            })
        })
        .collect();

    packet.insert("sections".to_string(), Value::Array(sections));
    (Value::Object(packet), source)
}

fn split_markdown(body: &str, issues: &mut Vec<Issue>) -> ParsedMarkdown {
    let mut title: Option<String> = None;
    let mut title_line = None;
    let mut title_problem_reported = false;
    let mut summary_lines = Vec::new();
    let mut sections = Vec::new();
    let mut current: Option<ParsedSection> = None;

    for (idx, line) in body.lines().enumerate() {
        let line_no = idx + 1;

        if let Some(rest) = line.strip_prefix("# ") {
            if title.is_some() {
                issues.push(Issue::at(
                    Some(line_no),
                    "packet Markdown must contain exactly one top-level # title. Use ## for sections.",
                ));
                continue;
            }
            title = Some(rest.trim().to_string());
            title_line = Some(line_no);
            continue;
        }

        if let Some(rest) = line.strip_prefix("## ") {
            if title.is_none() && !title_problem_reported {
                issues.push(Issue::at(
                    Some(line_no),
                    "packet Markdown must start with a # title before section headings",
                ));
                title_problem_reported = true;
            }

            if let Some(section) = current.take() {
                sections.push(section);
            }
            current = Some(ParsedSection {
                title: rest.trim().to_string(),
                line: line_no,
                lines: Vec::new(),
            });
            continue;
        }

        if title.is_none() && current.is_none() {
            if !line.trim().is_empty() && !title_problem_reported {
                issues.push(Issue::at(
                    Some(line_no),
                    "packet Markdown must start with a # title",
                ));
                title_problem_reported = true;
            }
            continue;
        }

        match current.as_mut() {
            Some(section) => section.lines.push((line_no, line.to_string())),
            None => summary_lines.push(line.to_string()),
        }
    }

    if let Some(section) = current {
        sections.push(section);
    }

    if title.is_none() && !title_problem_reported {
        issues.push(Issue::at(
            Some(1),
            "packet Markdown must start with a # title",
        ));
    }

    ParsedMarkdown {
        title,
        title_line,
        summary: trim_join(&summary_lines),
        sections,
    }
}

/// Turn a section's lines into rows. Returns the rows and the file line each
/// row starts on. A malformed `@hunk` line is reported and left out.
fn parse_section_rows(
    lines: &[(usize, String)],
    issues: &mut Vec<Issue>,
) -> (Vec<Value>, Vec<usize>) {
    let mut rows = Vec::new();
    let mut row_lines = Vec::new();
    let mut prose: Vec<(usize, String)> = Vec::new();

    for (line_no, line) in lines {
        if let Some(rest) = line.trim().strip_prefix("@hunk ") {
            push_prose_rows(&mut rows, &mut row_lines, &prose);
            prose.clear();

            match parse_hunk_row(rest.trim()) {
                Ok(row) => {
                    rows.push(row);
                    row_lines.push(*line_no);
                }
                Err(err) => issues.push(Issue::at(Some(*line_no), format!("{err:#}"))),
            }
        } else if markdown_subheading(line) {
            push_prose_rows(&mut rows, &mut row_lines, &prose);
            prose.clear();

            rows.push(json!({"kind": "markdown", "body": line.trim().to_string()}));
            row_lines.push(*line_no);
        } else {
            prose.push((*line_no, line.to_string()));
        }
    }

    push_prose_rows(&mut rows, &mut row_lines, &prose);

    (rows, row_lines)
}

fn push_prose_rows(rows: &mut Vec<Value>, row_lines: &mut Vec<usize>, lines: &[(usize, String)]) {
    for (line_no, body) in prose_rows(lines) {
        rows.push(json!({"kind": "markdown", "body": body}));
        row_lines.push(line_no);
    }
}

fn prose_rows(lines: &[(usize, String)]) -> Vec<(usize, String)> {
    let mut rows = Vec::new();
    let mut list_lines: Vec<(usize, String)> = Vec::new();

    for (line_no, line) in lines {
        let trimmed = line.trim();

        if trimmed.is_empty() {
            flush_list_rows(&mut rows, &mut list_lines);
        } else if markdown_list_item(trimmed) {
            list_lines.push((*line_no, trimmed.to_string()));
        } else {
            flush_list_rows(&mut rows, &mut list_lines);
            rows.push((*line_no, trimmed.to_string()));
        }
    }

    flush_list_rows(&mut rows, &mut list_lines);
    rows
}

fn flush_list_rows(rows: &mut Vec<(usize, String)>, list_lines: &mut Vec<(usize, String)>) {
    if let Some((first_line, _)) = list_lines.first() {
        let body = list_lines
            .iter()
            .map(|(_, line)| line.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        rows.push((*first_line, body));
        list_lines.clear();
    }
}

fn markdown_subheading(line: &str) -> bool {
    line.trim_start().starts_with("### ")
}

fn markdown_list_item(line: &str) -> bool {
    line.starts_with("- ")
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

/// Check a parsed packet's shape and its hunk coverage against the diff.
/// Coverage is only checked when the shape is sound enough to read hunk rows.
fn validate_packet(packet: &Value, diff: &DiffIndex, source: &SourceMap) -> Vec<Issue> {
    let mut issues = validate_shape(packet, source);
    if !issues.is_empty() && !source.markdown {
        return issues;
    }

    if diff.is_empty() {
        return issues;
    }

    let expected = expected_change_lines(diff);
    if expected.is_empty() {
        return issues;
    }

    // Each changed line maps to the file lines of the refs that cover it.
    let mut covered = BTreeMap::<ChangeLine, Vec<Option<usize>>>::new();

    for (section_idx, row_idx, row) in packet_hunk_rows(packet) {
        let line = source.row_line(section_idx, row_idx);
        let location = row_location(source, section_idx, row_idx);
        let (Ok(path), Ok(hunk_index)) =
            (string_field(row, "path"), usize_field(row, "hunk_index"))
        else {
            continue;
        };
        let Some(hunks) = diff.get(path) else {
            issues.push(Issue::at(
                line,
                format!(
                    "{location}packet references unknown file `{path}`. The diff has no changes to that file."
                ),
            ));
            continue;
        };
        let Some(hunk) = hunks.get(hunk_index - 1) else {
            issues.push(Issue::at(
                line,
                format!(
                    "{location}packet references unknown hunk `{path}#{hunk_index}`. That file has {} in the diff.",
                    plural(hunks.len(), "hunk")
                ),
            ));
            continue;
        };

        let (start, end) = match (
            optional_usize_field(row, "line_start"),
            optional_usize_field(row, "line_end"),
        ) {
            (Ok(Some(start)), Ok(Some(end))) => (start, end),
            (Ok(None), Ok(None)) => (1, hunk.row_count),
            (Err(err), _) | (_, Err(err)) => {
                issues.push(Issue::at(line, format!("{location}{err:#}")));
                continue;
            }
            _ => {
                issues.push(Issue::at(
                    line,
                    format!(
                        "{location}hunk rows must include both line_start and line_end or neither"
                    ),
                ));
                continue;
            }
        };

        if start == 0 || end == 0 || start > end || end > hunk.row_count {
            issues.push(Issue::at(
                line,
                format!(
                    "{location}packet references invalid slice `{path}#{hunk_index}:L{start}-L{end}`; hunk has {} rows",
                    hunk.row_count
                ),
            ));
            continue;
        }

        for row_number in hunk.changed_rows.range(start..=end) {
            let key = ChangeLine {
                path: path.to_string(),
                hunk_index,
                row: *row_number,
            };
            covered.entry(key).or_default().push(line);
        }
    }

    // Uncovered changed lines, grouped by hunk.
    let mut missing = BTreeMap::<(String, usize), Vec<usize>>::new();
    for line in expected.iter().filter(|line| !covered.contains_key(line)) {
        missing
            .entry((line.path.clone(), line.hunk_index))
            .or_default()
            .push(line.row);
    }
    for ((path, hunk_index), rows) in missing {
        issues.push(Issue::at(
            None,
            format!(
                "packet does not cover {} `{path}`#{hunk_index}:{}. Add `@hunk {path}#{hunk_index}` or a slice that includes {}.",
                if rows.len() == 1 { "changed line" } else { "changed lines" },
                format_rows(&rows),
                if rows.len() == 1 { "it" } else { "them" },
            ),
        ));
    }

    // Changed lines covered more than once, grouped by hunk and by the line of
    // the first ref that repeats them.
    let mut repeated = BTreeMap::<(Option<usize>, String, usize), (Vec<usize>, usize)>::new();
    for (line, refs) in covered.iter().filter(|(_, refs)| refs.len() > 1) {
        let entry = repeated
            .entry((refs[1], line.path.clone(), line.hunk_index))
            .or_default();
        entry.0.push(line.row);
        entry.1 = entry.1.max(refs.len());
    }
    for ((ref_line, path, hunk_index), (rows, count)) in repeated {
        issues.push(Issue::at(
            ref_line,
            format!(
                "packet covers {} `{path}`#{hunk_index}:{} more than once ({count} times). Each changed line must appear in exactly one hunk ref.",
                if rows.len() == 1 { "changed line" } else { "changed lines" },
                format_rows(&rows),
            ),
        ));
    }

    issues
}

/// `L2`, or `L2, L3, L5`.
fn format_rows(rows: &[usize]) -> String {
    rows.iter()
        .map(|row| format!("L{row}"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// For JSON packets, which have no line numbers, a prefix naming the section
/// and row. Empty for Markdown packets.
fn row_location(source: &SourceMap, section_idx: usize, row_idx: usize) -> String {
    if source.markdown {
        String::new()
    } else {
        format!("section {} row {}: ", section_idx + 1, row_idx + 1)
    }
}

fn validate_shape(packet: &Value, source: &SourceMap) -> Vec<Issue> {
    let mut issues = Vec::new();
    let Some(obj) = packet.as_object() else {
        issues.push(Issue::at(None, "packet must be a JSON object"));
        return issues;
    };

    // A Markdown packet with no `# ` line already has a parse issue for it.
    let title_already_reported = source.markdown && source.title_line.is_none();
    match obj.get("title").and_then(Value::as_str).map(str::trim) {
        Some(title) if !title.is_empty() => {}
        _ if title_already_reported => {}
        _ => issues.push(Issue::at(source.title_line, "packet title cannot be empty")),
    }

    let Some(sections) = obj.get("sections").and_then(Value::as_array) else {
        issues.push(Issue::at(None, "packet must include a sections array"));
        return issues;
    };

    for (section_idx, section) in sections.iter().enumerate() {
        let section_line = source.section_line(section_idx);
        let Some(section) = section.as_object() else {
            issues.push(Issue::at(
                section_line,
                format!("packet section {} must be an object", section_idx + 1),
            ));
            continue;
        };
        match section.get("title").and_then(Value::as_str).map(str::trim) {
            Some(title) if !title.is_empty() => {}
            _ => issues.push(Issue::at(
                section_line,
                format!("packet section {} must include a title", section_idx + 1),
            )),
        }
        let Some(rows) = section.get("rows").and_then(Value::as_array) else {
            issues.push(Issue::at(
                section_line,
                format!(
                    "packet section {} must include a rows array",
                    section_idx + 1
                ),
            ));
            continue;
        };
        for (row_idx, row) in rows.iter().enumerate() {
            let line = source.row_line(section_idx, row_idx);
            let location = row_location(source, section_idx, row_idx);
            let Some(kind) = row.get("kind").and_then(Value::as_str) else {
                issues.push(Issue::at(
                    line,
                    format!(
                        "packet section {} row {} must include kind",
                        section_idx + 1,
                        row_idx + 1
                    ),
                ));
                continue;
            };
            match kind {
                "markdown" => {
                    if row.get("body").and_then(Value::as_str).is_none() {
                        issues.push(Issue::at(
                            line,
                            format!("{location}markdown row must include body"),
                        ));
                    }
                }
                "hunk" => {
                    for err in [
                        string_field(row, "path").err(),
                        usize_field(row, "hunk_index").err(),
                    ]
                    .into_iter()
                    .flatten()
                    {
                        issues.push(Issue::at(line, format!("{location}{err:#}")));
                    }
                }
                other => issues.push(Issue::at(
                    line,
                    format!("{location}unknown packet row kind `{other}`"),
                )),
            }
        }
    }

    issues
}

/// Every hunk row with its section and row index.
fn packet_hunk_rows(packet: &Value) -> Vec<(usize, usize, &Value)> {
    packet
        .get("sections")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
        .flat_map(|(section_idx, section)| {
            section
                .get("rows")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .enumerate()
                .map(move |(row_idx, row)| (section_idx, row_idx, row))
        })
        .filter(|(_, _, row)| row.get("kind").and_then(Value::as_str) == Some("hunk"))
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
    fn parses_subheadings_as_separate_markdown_rows() {
        let packet = parse_markdown(
            r#"# Packet

## Section
Intro summary.

### Technical overview

Implementation notes.

@hunk lib/a.ex#1
"#,
        )
        .unwrap();

        let sections = packet["sections"].as_array().unwrap();
        let rows = sections[0]["rows"].as_array().unwrap();

        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0]["kind"], "markdown");
        assert_eq!(rows[0]["body"], "Intro summary.");
        assert_eq!(rows[1]["kind"], "markdown");
        assert_eq!(rows[1]["body"], "### Technical overview");
        assert_eq!(rows[2]["kind"], "markdown");
        assert_eq!(rows[2]["body"], "Implementation notes.");
        assert_eq!(rows[3]["kind"], "hunk");
    }

    #[test]
    fn parses_each_prose_line_as_its_own_markdown_row() {
        let packet = parse_markdown(
            r#"# Packet

## Section
First thought.
Second thought.

- grouped item
- another grouped item

@hunk lib/a.ex#1
"#,
        )
        .unwrap();

        let sections = packet["sections"].as_array().unwrap();
        let rows = sections[0]["rows"].as_array().unwrap();

        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0]["body"], "First thought.");
        assert_eq!(rows[1]["body"], "Second thought.");
        assert_eq!(rows[2]["body"], "- grouped item\n- another grouped item");
        assert_eq!(rows[3]["kind"], "hunk");
    }

    /// Run the same check `push` and `push --dry-run` use on a packet file.
    fn check_file(name: &str, body: &str, diff: &str) -> PacketCheck {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(name);
        fs::write(&path, body).unwrap();
        check_packet_for_diff(&path, diff).unwrap()
    }

    fn check_md(body: &str) -> Vec<Issue> {
        check_file("packet.md", body, DIFF).issues
    }

    fn only_issue(issues: Vec<Issue>) -> Issue {
        assert_eq!(issues.len(), 1, "issues = {issues:#?}");
        issues.into_iter().next().unwrap()
    }

    #[test]
    fn validates_full_changed_line_coverage() {
        let check = check_file("packet.md", PACKET, DIFF);
        assert!(check.is_valid(), "issues = {:#?}", check.issues);
        assert_eq!(check.packet.unwrap()["title"], "Narrative packet");
    }

    #[test]
    fn rejects_missing_changed_line_coverage() {
        let issue = only_issue(check_md("# T\n\n## S\n@hunk lib/a.ex#1:L2-L3"));
        assert_eq!(issue.line, None);
        assert!(issue
            .message
            .contains("does not cover changed lines `lib/a.ex`#2:L2, L3"));
    }

    #[test]
    fn rejects_duplicate_changed_line_coverage() {
        let issue = only_issue(check_md(
            "# T\n\n## S\n@hunk lib/a.ex#1\n@hunk lib/a.ex#1:L2-L3\n@hunk lib/a.ex#2",
        ));
        assert_eq!(issue.line, Some(5));
        assert!(issue.message.contains("more than once (2 times)"));
    }

    #[test]
    fn rejects_unknown_hunk_refs() {
        let issues = check_md("# T\n\n## S\n@hunk lib/a.ex#1\n@hunk lib/a.ex#2\n@hunk lib/a.ex#3");
        let issue = only_issue(issues);
        assert_eq!(issue.line, Some(6));
        assert!(issue.message.contains("unknown hunk `lib/a.ex#3`"));
        assert!(issue.message.contains("2 hunks"));
    }

    #[test]
    fn rejects_unknown_files() {
        let issues = check_md("# T\n\n## S\n@hunk lib/a.ex#1\n@hunk lib/a.ex#2\n@hunk lib/b.ex#1");
        let issue = only_issue(issues);
        assert_eq!(issue.line, Some(6));
        assert!(issue.message.contains("unknown file `lib/b.ex`"));
    }

    #[test]
    fn rejects_invalid_slice_ranges() {
        let issues = check_md("# T\n\n## S\n@hunk lib/a.ex#1:L2-L8\n@hunk lib/a.ex#2");
        // The bad slice covers nothing, so hunk 1's lines are also uncovered.
        assert_eq!(issues.len(), 2, "issues = {issues:#?}");
        assert_eq!(issues[0].line, Some(4));
        assert!(issues[0].message.contains("invalid slice"));
        assert!(issues[1].message.contains("does not cover"));
    }

    #[test]
    fn reports_malformed_hunk_refs_with_their_line() {
        let issues = check_md(
            "# T\n\n## S\n@hunk lib/a.ex#1\n@hunk lib/a.ex#2\n@hunk lib/a.ex\n@hunk lib/a.ex#0",
        );
        assert_eq!(issues.len(), 2, "issues = {issues:#?}");
        assert_eq!(issues[0].line, Some(6));
        assert!(issues[0].message.contains("must look like `@hunk path#N`"));
        assert_eq!(issues[1].line, Some(7));
        assert!(issues[1].message.contains("hunk number must be >= 1"));
    }

    #[test]
    fn reports_markdown_structure_problems_with_their_line() {
        let issues = check_md("intro\n# T\n\n## \n@hunk lib/a.ex#1\n# Again\n@hunk lib/a.ex#2");
        let lines: Vec<_> = issues.iter().map(|i| i.line).collect();
        assert_eq!(
            lines,
            vec![Some(1), Some(4), Some(6)],
            "issues = {issues:#?}"
        );
        assert!(issues[0].message.contains("must start with a # title"));
        assert!(issues[1].message.contains("section 1 must include a title"));
        assert!(issues[2].message.contains("exactly one top-level # title"));
    }

    #[test]
    fn reports_every_problem_in_one_pass() {
        let issues = check_md("# T\n\n## S\n@hunk lib/a.ex#9\n@hunk nope\n");
        // unknown hunk, malformed ref, and both hunks uncovered.
        assert_eq!(issues.len(), 4, "issues = {issues:#?}");
    }

    #[test]
    fn missing_title_is_reported_once() {
        let issue = only_issue(check_file("packet.md", "", "").issues);
        assert_eq!(issue.line, Some(1));
        assert!(issue.message.contains("# title"));
    }

    #[test]
    fn reports_json_syntax_errors_with_their_line() {
        let check = check_file("packet.json", "{\n  \"title\": \"T\",\n  oops\n}", DIFF);
        assert!(check.packet.is_none());
        let issue = only_issue(check.issues);
        assert_eq!(issue.line, Some(3));
        assert!(issue.message.contains("not valid JSON"));
    }

    #[test]
    fn reports_json_shape_errors_by_section_and_row() {
        let check = check_file(
            "packet.json",
            r#"{"title":"T","sections":[{"title":"S","rows":[{"kind":"hunk","path":"lib/a.ex"},{"kind":"video"}]}]}"#,
            DIFF,
        );
        assert_eq!(check.issues.len(), 2, "issues = {:#?}", check.issues);
        assert!(check.issues[0]
            .message
            .contains("section 1 row 1: hunk rows must include positive integer `hunk_index`"));
        assert!(check.issues[1]
            .message
            .contains("section 1 row 2: unknown packet row kind `video`"));
    }

    #[test]
    fn into_packet_lists_every_issue_with_file_and_line() {
        let check = check_file("packet.md", "# T\n\n## S\n@hunk lib/a.ex#9\n", DIFF);
        let err = check.into_packet().unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("has 3 problems"), "msg = {msg}");
        assert!(
            msg.contains("packet.md:4: packet references unknown hunk"),
            "msg = {msg}"
        );
        assert!(
            msg.contains("packet.md: packet does not cover"),
            "msg = {msg}"
        );
    }

    #[test]
    fn summarizes_sections_hunk_refs_and_files() {
        let packet = parse_markdown(PACKET).unwrap();
        let summary = summarize(&packet);
        assert_eq!(summary.title, "Narrative packet");
        assert_eq!(summary.hunk_refs, 2);
        assert_eq!(summary.sections.len(), 1);
        assert_eq!(summary.sections[0].hunk_refs, 2);
        assert_eq!(
            summary.files.into_iter().collect::<Vec<_>>(),
            vec!["lib/a.ex"]
        );
        assert_eq!(
            diff_files(DIFF),
            vec![DiffFile {
                path: "lib/a.ex".to_string(),
                hunks: 2
            }]
        );
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

        let packet = check_packet_for_diff(&path, DIFF)
            .unwrap()
            .into_packet()
            .unwrap();
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
