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

## Structure Preferences

Treat each `##` section as an approval unit. A reviewer should be able to approve the section without implicitly approving unrelated risks.

Shape sections around independent review decisions, not just file adjacency. Split a section when it mixes substantial concerns such as:
- persistence/schema changes and runtime behavior,
- backend API contracts and CLI/client wiring,
- UI behavior/templates and design-system or CSS primitives,
- implementation hunks and broad regression coverage,
- feature work and packet/tooling/documentation changes.

As a rough check, reconsider any section with more than 10-15 hunks, 300-400 changed lines, or 10 files. Large sections are fine only when the hunks are mechanically inseparable or share one clear approval meaning.

Avoid catch-all sections such as "Supporting integration" unless every hunk in the section supports the same review decision. Prefer moving glue files into the section that owns their risk.

When the best structure is unclear, ask the user which organization practice they prefer before finalizing or pushing the packet. Ask when you lack confidence about tradeoffs such as:
- splitting by system layer versus user workflow,
- keeping API and CLI together versus separating server/client changes,
- grouping tests with implementation versus placing tests in a dedicated section,
- preserving existing section titles for approval inheritance versus reshaping the packet for a clearer review.

Keep the question short and offer concrete options. If the user is unavailable and the packet must proceed, state the assumption in the packet overview and choose the structure that makes approvals most independent.

## Hunk Lead-Ins

Lead-ins should orient the reviewer to the code they are about to see, not announce the file path or repeat the section title. Keep them short enough to fit in about two tablet lines: aim for 16-28 words, one sentence when possible.

Before writing a lead-in, skim the surrounding module, schema, caller, or template so you can name context that may not appear inside the hunk. Good lead-ins usually include:
- the file's role in the system,
- the behavior this hunk connects to,
- the hidden risk, invariant, or compatibility concern worth reviewing.

Avoid boilerplate like:

```markdown
Review lib/reviews/accounts.ex for the identity data model and authorship changes.
```

Prefer contextual lead-ins:

```markdown
Accounts owns the split between GitHub owners and acting identities. Watch token minting and lookup paths for owner-vs-actor drift.

This migration bridges old user-authored rows to identity-authored rows. The risky parts are backfill order and FK delete behavior.

Settings is becoming the account control surface. Keep signed-out, human identity, agent identity, and one-time-token states easy to scan.
```

When several adjacent hunks in the same file are mechanical or serve the same purpose, write one lead-in before the run of hunk refs instead of repeating a line before every hunk.

## Hunk Selection

- Cover every changed line exactly once unless intentionally grouping duplicate ref coverage is acceptable for the current tool.
- Use full hunk refs for small cohesive changes.
- If one large hunk contains multiple review topics, split the surrounding prose instead of using sliced hunk refs.
- Keep generated files, lockfiles, or purely mechanical output out of the packet unless they need review.
- If the packet is only for local review, put it in `/private/tmp` or another temporary path to avoid accidentally committing it.

## Pre-Push Packet Review

Before pushing, audit the packet:
1. Confirm every changed line is covered by exactly one intended hunk ref.
2. Count hunks, files, and changed-line weight per section.
3. Split any section whose approval would bless multiple unrelated concerns.
4. Move glue files into the section that owns their risk.
5. Give packet/tooling/docs-only changes their own tiny section, or omit them when review would not be useful.
6. Trim lead-ins that repeat paths, repeat section titles, or read longer than two short tablet lines.
7. If the sectioning choice still feels uncertain, ask the user for their preferred organization before pushing.

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
