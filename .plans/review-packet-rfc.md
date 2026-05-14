# RFC — Review Packets for Agentic Reviews

**Status:** Draft v2
**Owner:** _TBD_
**Date:** 2026-05-14
**Decision needed by:** _TBD_

**TL;DR.** Attach a structured packet to each pushed patchset that directs reviewer attention — invariants, a grouped tour of the diff, manual testing checks, and open questions. Validate by measuring whether reviews reach approval faster than comparable GitHub PRs without an increase in post-merge bug rate.

**Companion docs:**
- PRD — lifecycle, user stories, flow diagrams: [`./review-packet-prd.md`](./review-packet-prd.md)
- Spec — schemas, anchoring, CLI format, rendering boundary: [`./review-packet-spec.md`](./review-packet-spec.md)

---

## 1. Problem

The shift to agent-authored diffs changes the reviewer's job. Changes are larger, the shared context is gone (no Slack thread the reviewer was on, no in-person whiteboarding), and the author can't be poked for clarification mid-review. The current diff-plus-free-form-description surface assumes a human author available to answer questions inline. As a result reviewers spend their time *deciding where to look* rather than reading code — and our tooling doesn't help with that. The bottleneck has shifted and our review surface has not.

## 2. Proposed solution

A **review packet** is structured metadata the author (typically an agent) attaches to each patchset. Six sections, each answering a distinct reviewer question:

| Section | Reviewer question |
| --- | --- |
| **Summary** | What is this, in one line? |
| **Invariants** | What must I trust? |
| **Tour** | What changed and why? |
| **Testing** | What should I verify by hand? |
| **Rollout** | What happens at deploy? |
| **Open questions** | What decisions need me? |

Per-reviewer state (testing-check progress, hunk approvals) carries across patchset updates via the content-hash anchoring already used for comment threads, so partial review work isn't thrown out when the agent pushes again. The packet has a lifecycle — **Draft → In Review → Approved** — that mirrors the agent's loop: prepare in private, hand off, iterate on feedback, freeze as a historical record. The PRD walks the lifecycle and the stories in detail.

The packet is optional metadata. Reviews without one render exactly as they do today.

## 3. Why now

- **Agent-authored PRs are climbing** across the org; review is becoming the binding constraint on agentic workflows.
- **The platform pieces are already in place** — `@pierre/diffs` for rendering, thread anchoring for survival across patchsets, the patchset model. We're extending, not building from scratch.
- **The existing review surface absorbs the change.** No fork, no migration, no new product surface to staff.

## 4. What we'd measure

**Hypothesis.** PRs pushed through the new tooling reach approval faster than comparable GitHub PRs, *without* a corresponding rise in post-merge bug rate.

**Primary metric.** Time-to-approval (not time-to-merge — merge timing is dominated by CI, deploy windows, and batching, none of which are about review quality).

**Guardrail metric.** Post-merge revert / bug rate. Faster is a degenerate win if reviewers are rubber-stamping; the guardrail catches that.

**Secondary signals.** Patchset count per review, number of feedback rounds, reviewer-reported time, open-question answered rate.

**Cohorts.** Match by change-size bucket (LOC + files), author type (human vs. agent), and repo. A naive packet-vs-GitHub aggregate would drown in variance — most of the time-to-approval signal is in change size and author.

**Window.** 4–8 weeks of parallel dogfooding for quantitative signal; two weeks of qualitative use earlier to debug the surface.

**Falsifier.** If time-to-approval doesn't move, or it moves and the guardrail bug rate rises, the hypothesis is wrong and we don't invest beyond MVP.

## 5. Scope

**In MVP:** packet schema; render surface above the existing diff; CLI delivery via `.reviews/packet.json`; per-reviewer check progress and hunk approval (informational coverage map, no gating); update delta between patchsets.

**Out for MVP:** multi-service / cross-packet linking, third-party integrations (Linear / Slack / Figma / Notion APIs), merge gating on per-hunk coverage, automated invariant verification.

**Cost estimate.** ~2 weeks of single-engineer focused work. Most of the surface is the LiveView render and anchoring glue; the existing thread infrastructure does the heavy lifting. Spec breaks the surface down by component.

## 6. Risks & tradeoffs

- **Agent self-flagging accuracy.** Packets only help if the agent reliably surfaces real risks, real invariants, and real open questions. A poorly-written packet is worse than no packet — it directs attention away from real issues. Mitigation: pair MVP rollout with prompt iteration and a small qualitative review of the first ~20 packets generated.
- **Section sprawl.** Six sections is the upper cognitive bound for a single artifact. We expect requests for "performance impact," "security review," "API compatibility," etc. The bar for new sections is the same one we used here: it has to answer a distinct reviewer question.
- **Cargo-culting (especially rollout plans).** Agents will reach for "feature flag this" reflexively on changes that don't need it. Empty sections are better than performative ones; the prompt and the schema both treat optional sections as suppressable.

## 7. How to contribute

- **Team leads** — nominate one bug or small feature your team will dogfood the tool on. Aim for variety across change size. Coordinate with the owner.
- **Designers** — the coverage-map UX (per-step approval visualization) is open. See PRD §"Approved — historical / archival view" and open question 4.
- **Platform engineers** — anchoring drift edge cases need someone who knows that code. See spec §6 (anchoring & drift) and §12 (validation / edge cases).
- **Leadership** — sign off on the scope cuts in §5, and weigh in on whether merge gating on coverage belongs in MVP or stays out.

## 8. Reference

- **PRD:** [`./review-packet-prd.md`](./review-packet-prd.md) — lifecycle, stories, flow diagrams.
- **Spec:** [`./review-packet-spec.md`](./review-packet-spec.md) — schemas, anchoring, CLI integration, rendering boundary.
- **Branch:** `claude/review-packet-design-6iw4V`.
