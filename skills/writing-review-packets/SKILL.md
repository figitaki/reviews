---
name: writing-review-packets
description: Create or revise Reviews packets that explain a code diff with rich Markdown, reviewer guidance, and interwoven hunk references. Covers section strategy, rendering limits, validation, and packet revisions with the Reviews CLI. Use when asked to write a review packet, organize a diff for review, add narrative context, or update a packet for a new patchset.
---

# Writing Review Packets

Use this skill when drafting packets for `reviews push --packet`. Write an authored reading experience, not an annotated file list: explain the change, guide the reviewer's judgment, and interleave the relevant code. Use rich Markdown to make the reasoning easy to scan, without decorating every sentence or restating the diff.

## Packet Markdown Format

Use one top-level title and `##` packet sections:

```markdown
# Retry failed deliveries without duplicating work

**Failed delivery should be recoverable, not repeat the operation.** This change separates accepting work from delivering its result. Existing successful requests keep the same behavior.

Read the review in this order:

- **Storage:** check that a retry keeps the original operation identity.
- **Delivery:** check what happens after a timeout or worker restart.

## Preserve operation identity across retries

The persisted operation is the boundary between *new work* and *another delivery attempt*. Approving this section means accepting that identity and its migration behavior.

- **Invariant:** a retry reuses the original operation ID.
- **Compatibility:** existing completed operations remain unchanged.
- **Review focus:** a concurrent retry must not create another operation.

The [migration guide](https://example.com/migrations) describes the rollout constraint. Check the uniqueness boundary here before reviewing the worker behavior.

@hunk lib/deliveries/operation.ex#1

*The failure path matters most:* a timeout must leave the operation available for another delivery attempt, not erase its identity.

@hunk lib/deliveries/worker.ex#1
```

Rules:
- Start with exactly one `#` title.
- Use `##` for review packet sections.
- Prose between hunk refs is allowed and encouraged.
- Hunk refs use `@hunk path#N`.
- Paths and hunk numbers must match the diff being pushed.
- The first prose paragraph in each section is its overview; write it as durable review reasoning, not as a terse hunk caption.

## Rich Content and Rendering Limits

- Open with the outcome, scope, and a useful reading order. Put cross-cutting context before the first `##` section so it appears on Overview.
- Use **bold** for important invariants or review questions, *italics* for nuance, and inline code for identifiers or short commands. Keep ordinary prose readable without the formatting.
- Use lists for distinct guarantees, risks, verification results, or steps. Choose forms that help this change; do not force every packet into the same checklist.
- Link to relevant specifications, issues, or design decisions using descriptive labels. Use real, accessible destinations, not invented links or local filesystem paths. Repository-relative links are not automatically resolved against the source repository; use full repository URLs for source links.
- Add a small code example, table, or diagram only when it explains something the diff does not. Distinguish intended behavior from behavior exercised by tests; include actual commands and results when reporting verification.
- Authored HTML is escaped. Links may use HTTP, HTTPS, or mailto; avoid custom or executable schemes. Images render only from SVGs already bundled by the Reviews server at `/images/<basename>.svg`; packet uploads do not upload image assets. Do not use remote image services for private code or architecture.
- Mermaid fences are not rendered as diagrams. For interactions, show the user, agent, and service as distinct parties, label who initiates each step, and make revision/feedback loops explicit. Use an already bundled diagram only if it describes the actual change; otherwise use a text diagram or explain the flow in prose. Adding a new bundled SVG requires a separate server asset change.
- The current CLI Markdown parser preserves top-level `- ` lists together but splits other section prose line by line. Keep Markdown paragraphs on one source line. For multiline fenced code, tables, nested/ordered lists, or text diagrams inside a section, use a JSON packet with the whole block in one `{"kind":"markdown","body":"..."}` row, and preview it. Keep `#`, `##`, and `@hunk` structural lines out of literal examples in Markdown packets: the parser does not recognize fence boundaries.

In a checkout of Reviews, read `priv/examples/section_review_performance.packet.md` for the demo's narrative style. Borrow the presentation, not its historical claims, diagram, file paths, or hunk references.

## Writing Method

1. Inspect the diff with `git diff` or the intended CLI range.
2. Identify logical review areas: persistence/schema, read model, LiveView state, rendering, styling, tests, tooling.
3. Prefer stable section titles if updating an existing packet and you want approvals to inherit.
4. Put a reasoning-first overview paragraph at the top of each `##` section. Explain why the grouped changes exist, what approving them means, and how to review them.
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

Lead-ins should orient the reviewer to the code they are about to see, not announce the file path or repeat the section title. Prefer one short sentence; use a longer explanation or list when a real risk or tradeoff needs it.

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
6. Trim lead-ins that repeat paths, section titles, or visible code without adding reasoning.
7. Check that Overview explains the outcome and reading order, and that formatting and links help the reviewer make decisions rather than add decoration.
8. Check the installed `reviews push --help` before choosing validation flags. This checkout's CLI validates packet structure and coverage before uploading but has no `--dry-run`; do not upload just to validate without permission. After an authorized upload, inspect Overview and a representative section on the target server; verify lists, links, and any code or diagrams. Structure validation does not check browser rendering. If a preview is unavailable, report that limitation.
9. If the sectioning choice still feels uncertain, ask the user for their preferred organization before pushing.

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
