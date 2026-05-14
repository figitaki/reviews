# RFC — Review Packets for Agentic Reviews

**Status:** Draft
**Branch:** `claude/review-packet-design-6iw4V`
**Detailed spec:** [`./review-packet-spec.md`](./review-packet-spec.md)

---

## Summary

A **review packet** is a structured artifact the author (typically an agent) attaches to each pushed patchset. It tells the reviewer what to trust, what to read, what to verify, what to coordinate at deploy, and what decisions still need a human. The packet is rendered above the existing diff and is regenerated per patchset; reviewer state (checklist progress, hunk approvals) is tracked separately so it survives updates via content-hash anchoring.

Same URL, same review surface, same threads model. A packet is metadata on a patchset that may or may not be present — agent pushes always include one, manual pushes usually don't.

## Motivation

Reviews today are oriented around humans authoring a diff and another human reading it line by line. When the author is an agent, two things change:

1. **Volume goes up.** A turn of agent work can plausibly produce 800 LOC across 20 files.
2. **The "why" leaves the author's head, not the reviewer's.** The reviewer has no shared context, no Slack thread they were copied on, no sense of which decisions were made deliberately versus drifted into.

The reviewer's bottleneck shifts from *reading code* to *deciding where to look*. A raw diff plus a free-form PR description doesn't direct attention well. The packet is a structured handoff that does.

## Goals

- **Direct reviewer attention** rather than describe what happened.
- **Survive patchset updates** so prior review state (approvals, completed checks, resolved threads) carries forward via hunk-anchoring instead of being thrown out.
- **Separate author claims from reviewer verification state** cleanly. The agent says what's true; the reviewer says what they checked.
- **Scale across change sizes** without shape change — same packet model for a one-line typo fix and a multi-step feature.
- **Stay queryable.** Sections like invariants and open questions are first-class records, not embedded in prose.

## Non-goals (for this RFC)

- Automatic verification of invariants.
- Cross-packet linking for multi-service changes. The single-packet hypothesis is tested first.
- Agent autonomy (branch spinning, auto-push). The packet is what the agent produces, not how.
- Deploy-pipeline consumption of rollout plans.
- Token-level commenting (already deferred to v1.5; see CLAUDE.md).

## Flow

```mermaid
sequenceDiagram
    actor Agent
    participant CLI as reviews CLI
    participant Server as Phoenix
    actor Reviewer

    Agent->>Agent: produce code + .reviews/packet.json
    Agent->>CLI: reviews push
    CLI->>Server: diff + packet
    Server-->>Reviewer: /r/<slug> renders packet above diff

    Reviewer->>Server: tick checks, approve steps, reply to OQs
    Server-->>Agent: open question replies (via thread API)

    Agent->>Agent: address replies, edit code + packet
    Agent->>CLI: reviews push --update <slug>
    CLI->>Server: new patchset + new packet
    Server->>Server: rehydrate anchors; carry forward unchanged state
    Server-->>Reviewer: update delta highlighted
```

The author-side loop is: write code, write the packet, push. The reviewer-side loop is: read the packet, react to it (check, approve, reply), wait for the next push. Iteration is driven by replies to open questions — the agent reads them between pushes and adjusts.

## Packet shape

Six sections, each answering a distinct reviewer question:

| Section | Reviewer question |
| --- | --- |
| **Summary** | What is this, in one line? |
| **Invariants** | What must I trust? |
| **Tour** | What changed and why? |
| **Testing** | What should I verify by hand? |
| **Rollout** | What happens at deploy? |
| **Open questions** | What decisions need me? |

Internally, every section is a sequence of **rows**, where a row is either a prose block (markdown with a small inline-component palette) or a diff hunk. This lets evidence sit next to claims — an invariant can include the hunk that proves it; a testing step can show the error string it should produce. Tour is the one section that retains additional structure: it's a list of *steps*, each with a heading, a body of rows, and the hunks it owns, so steps remain addressable for cross-references and update deltas.

The packet is **optional**. Reviews without a packet render exactly as they do today.

## Reviewer interaction model

Two things in a packet are *interactive* and accumulate state per reviewer:

**Testing checks.** Each check has independent state per reviewer: unchecked, verified, failed, skipped. Bob can see that Alice already verified a step — that's part of the value, so they don't redo each other's work. Checks anchor to hunks; if a patchset update changes the anchor hunks, the check is flagged "needs re-verification." Otherwise the prior ✓ stands.

**Hunk approvals.** Approval is per-hunk in the data model, but exposed at **tour-step granularity** in the UX — approving "step 3: CSV generator using Repo.stream" marks each of its hunks approved by that reviewer. This matches the conceptual unit of change without forcing reviewers to make 50 decisions per patchset. Hunks not in any step (the "Other" bucket) get bucket-level approval.

For MVP, hunk approvals are **purely informational** — a coverage map showing which steps each reviewer has signed off on. They do not gate merge. Existing review-level approval still drives the merge button. Gating policy can be layered on once there's real data on usage patterns.

## Patchset iteration

Each push is a new patchset; each patchset gets its own packet. The page shows the **current** patchset by default, with an **update delta** block summarizing what changed since the previous one:

- which open questions this patchset addressed,
- which tour steps changed (added / removed / hunks differ),
- which invariants are new.

Existing review state (comment threads, completed checks, hunk approvals) carries forward by content-hash anchoring. Anchors that no longer match invalidate their dependent state, surfacing it as "needs re-verification" rather than silently losing it.

## User stories

### 1. Trivial: typo fix
Packet has a one-line summary, two invariants ("only copy changed," "tests green"), and a single tour step with the one-line diff inline. No testing checks beyond "no manual verification needed." No rollout. No open questions. Reviewer glances, merges. The packet doesn't get in the way.

### 2. Scoped bug fix with a judgment call
The agent fixes a stale-cache bug. Invariants name the property restored (cache invalidated on delete) with pointers at the regression test. The tour is two steps. Testing checklist has two manual repros tied to the original repro video. One open question: *"Should we backfill old deleted docs? I treated it as out of scope."* The reviewer answers, the agent files a follow-up ticket, marks the OQ resolved, no code change. The packet's value lives in the OQ.

### 3. Simple feature with iteration
CSV export across route + generator + LiveView. Four-step tour, four invariants with evidence (filter respected, admin-only, streams, no new deps), three testing checks, two open questions (filename format, row cap policy). Reviewer answers both, leaves one inline comment. Agent updates; the update delta is "addressed 2 OQs, addressed 1 inline thread, added one new invariant (1M row cap)." Reviewer reads the delta only, approves, merges. This is where the patchset model earns its keep.

### 4. Multi-service change
*Out of scope for MVP.* The single-packet hypothesis is validated first. Multi-service is sketched in the spec under "Future work" with cross-packet sibling references and dependency hints, but the MVP ships only single-packet flows.

## MVP scope

**In:**
- Packet structure: summary, invariants, tour (with steps), testing, rollout (optional), open questions.
- `Row = Markdown | Hunk` primitive uniformly across sections; tour steps additionally carry heading + hunk list.
- Per-reviewer check progress, anchored to hunks.
- Per-reviewer hunk approvals (informational coverage map, no gating).
- Update delta between patchsets.
- CLI delivery: `.reviews/packet.json` (or `--packet path`) picked up by `reviews push`.
- Render above the existing diff in the LiveView; reuse the existing React island for diff rendering, HEEx for new chrome.

**Out:**
- Automated invariant verification.
- Multi-service / cross-packet linking, sibling chips, dependency hints.
- Linear / Slack / Figma / Notion API integrations (references are free-form `{label, url}` chips).
- Merge-gating semantics tied to per-hunk approvals or check completion.
- Agent autonomy.

See the spec for what each "in" item entails technically.

## Open questions

1. **Should the packet ever be editable post-push?** Today: no. The agent re-pushes a patchset to amend. But a reviewer noticing a typo in the agent's prose might want to fix it without forcing a new patchset. Punt to post-MVP.
2. **Does "no open questions" need a placeholder, or do empty sections disappear?** Probably they disappear (less noise on small packets). Rollout already disappears when empty; consistency suggests OQs do too.
3. **Where do agent self-verification results live?** Sketched as a sub-block of the Testing section ("performed by agent: …"). Worth confirming this is the right home versus a peer of testing.
4. **Coverage map UX.** The data model supports per-hunk approval; the UX exposes step-level. What does the coverage map *look like* in the sidebar — a step-by-step list with reviewer avatars, or something denser? Design open.

## Reference

The detailed spec at [`./review-packet-spec.md`](./review-packet-spec.md) covers:

- Architecture and component boundaries
- Ecto-shaped schemas for `Packet`, `Step`, `Check`, `ReviewerCheckProgress`, `HunkApproval`
- The Row primitive and the allowed MDX component palette inside prose
- Hunk-anchoring algorithm and drift behavior across patchsets
- Update-delta computation
- CLI packet file format
- Notes on the LiveView/React boundary
