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

The first paragraph is the section overview. Use it to explain the reasoning behind this part of the changeset: what problem this section solves, why the files belong together, and what judgment the reviewer should bring to the code. It can be a full paragraph when the change needs that context.

Context before a hunk should connect the local code to that section overview. It can be a short paragraph when useful, especially when the surrounding code shape, dependency order, risk, or intended reviewer attention would otherwise be unclear.

@hunk path/to/file.ex#1
```

Rules:
- Start with exactly one `#` title.
- Use `##` for review packet sections.
- Prose between hunk refs is allowed and encouraged.
- Hunk refs use `@hunk path#N`.
- Paths and hunk numbers must match the diff being pushed.
- The first prose paragraph in each section is the section overview shown in the guide rail; write it as durable review reasoning, not as a terse hunk caption.

## Writing Method

1. Inspect the diff with `git diff` or the intended CLI range.
2. Identify logical review areas: persistence/schema, read model, LiveView state, rendering, styling, tests, tooling.
3. Prefer stable section titles if updating an existing packet and you want approvals to inherit.
4. Put a reasoning-first overview paragraph at the top of each `##` section. This first paragraph is the primary guide-rail content, so it should explain why the grouped changes exist and how to review them.
5. Use `###` subheadings sparingly, only when a section truly needs scan landmarks; do not add a stock technical-overview subsection to every section.
6. Add interwoven hunk comments before hunks when they help the reader understand the surrounding code and how the local change supports the section overview.
7. Hunk comments no longer need to be ultra-terse. Prefer the shortest useful explanation, but use two to four sentences when needed to carry code context, tradeoffs, dependency order, risk, or review intent.
8. Avoid hunk comments that restate the diff; explain why this code is shaped this way, what to inspect, or how it relates back to the section's primary overview.
9. Keep section decisions independent from hunk viewed progress in wording.

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
