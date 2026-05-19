---
name: writing-review-packets
description: Create or revise Reviews packet markdown for a code diff, including section strategy, prose, hunk references, validation, and pushing packet revisions with the Reviews CLI. Use when the user asks to write a review packet, organize a diff for review, add prose around hunk refs, update a packet for a new patchset, or push a packet to a local or hosted Reviews instance.
---

# Writing Review Packets

Use this skill when drafting packet markdown for `reviews push --packet`. A good packet is a reviewer map: it groups related hunks, explains why to look, and avoids rephrasing the diff line-by-line.

## Packet Markdown Format

Use one top-level title and `##` packet sections:

```markdown
# Packet Title

Short overview of what the review packet covers.

## Section Title

One or two sentences orienting the reviewer.

### Technical overview

More detailed explanation of implementation shape, decisions, tradeoffs, and explorations.

One sentence of context before the hunk when useful.

@hunk path/to/file.ex#1
```

Rules:
- Start with exactly one `#` title.
- Use `##` for review packet sections.
- Prose between hunk refs is allowed and encouraged.
- Hunk refs use `@hunk path#N`.
- Paths and hunk numbers must match the diff being pushed.

## Writing Method

1. Inspect the diff with `git diff` or the intended CLI range.
2. Identify logical review areas: persistence/schema, read model, LiveView state, rendering, styling, tests, tooling.
3. Prefer stable section titles if updating an existing packet and you want approvals to inherit.
4. Put a 1-2 sentence summary at the top of each `##` section.
5. Add a `### Technical overview` when the section has non-obvious design, tradeoffs, or rejected alternatives.
6. Add terse hunk explainers before hunks when they help the reader know what to look for.
7. Avoid hunk explainers that restate the diff; explain context, dependency order, risk, or review intent.
8. Keep section decisions independent from hunk viewed progress in wording.

## Hunk Selection

- Cover every changed line exactly once unless intentionally grouping duplicate ref coverage is acceptable for the current tool.
- Use full hunk refs for small cohesive changes.
- If one large hunk contains multiple review topics, split the surrounding prose instead of using sliced hunk refs.
- Keep generated files, lockfiles, or purely mechanical output out of the packet unless they need review.
- If the packet is only for local review, put it in `/private/tmp` or another temporary path to avoid accidentally committing it.

## Approval Inheritance

Section approvals inherit across patchsets only when the packet section identity and refs still match well enough.

To preserve approvals:
- Keep section titles stable.
- Keep hunk refs in the same conceptual section.
- Add new sections for new work instead of rewriting the whole packet.

To intentionally invalidate approvals:
- Restructure sections around a new review strategy.
- Change section titles and hunk membership.

## Push Workflow

Use the CLI from the git checkout being reviewed:

```bash
reviews push --packet /path/to/packet.md
reviews push --update <slug> --packet /path/to/packet.md
reviews push --update <slug> --range HEAD --packet /path/to/packet.md
```

Notes:
- `--range HEAD` captures current working-tree changes.
- Default capture is usually `HEAD~1..HEAD`; use an explicit range when needed.
- If validation fails with an uncovered changed line, add or adjust hunk refs until the packet covers the diff.
- Do not commit local packet files unless the user explicitly wants them tracked.
