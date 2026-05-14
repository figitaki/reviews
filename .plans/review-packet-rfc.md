# RFC: Review packets for agent-authored PRs

**Status:** Draft
**Author:** [figitaki](https://github.com/figitaki)
**Date:**  2026-05-14

## Summary

[Reviews](https://reviews-dev.fly.dev) aims to solve the issues that arise from the increased throughput required for modern code review practices in the age of LLM assisted coding. Attach a structured packet to each PR patchset that tells reviewers where to look, what to trust, and what needs a decision. Measure whether this brings agent-authored PRs to approval faster without a regression in stability (bugs).

## Problem

Agent-authored diffs are getting larger and the review surface has not changed. The standard issue diff view assumes a human author who was in the meeting, wrote the PR description from memory, and can answer questions inline. Agent PRs break all three assumptions: no shared context, no author to ping, and often a change size that makes "read everything" impractical.

A compilation of specific grievances:
* Automatically generated PR descriptions are verbose and opaque, **not a time save**, often require significant trimming.
* Linear ordering of changes by alphabetic filename sorting doesn't match the order reviewers follow (logical).
* Conversations can get lost in deep timelines on the PR overview page with commits, copilot reviews, bot comments, open comments + reviews
  * No quick view into what is open and who it's blocked on.
* Draft PRs, *especially in public repos*, are not suitable for initial reviews agent output
* Code signing policies aren't compatible with current tooling. Agents **SHOULD NOT** sign their own code, human author + reviewers **MUST**.
* GitHub has been having significant [reliability issues](https://www.githubstatus.com/).

Reviewers end up deciding where to start rather than actually reviewing.

## What we are proposing

A **review packet** is structured metadata the author attaches to each patchset. Six sections, each answering a specific question:

| Section | Reviewer question |
|---|---|
| Summary | What is this, in one line? |
| Invariants | What must I trust? |
| Tour | What changed and why? |
| Testing | What should I verify by hand? |
| Deploy | What happens at deploy? |
| Open questions | What decisions need me? |

The packet has a lifecycle — draft, in review, approved — that matches the agent loop. Per-reviewer progress (which hunks they have covered, which testing checks they have run) carries across patchset updates via content-hash anchoring. Push a new patchset, and partial review work survives.

No packet means the PR renders exactly as it does today. This is optional metadata.

## Why now

Agent-authored PRs are climbing. Review is where they stall. The platform pieces are already in place: a diff renderer, per-hunk thread anchoring, a patchset model. This is an extension, not a new surface.

## What we would measure

### Primary Metric
Time from patchset push to approval.

### Guardrail
Post-merge revert and bug rate. Faster reviews that miss bugs are not wins.

### Cohort Matching
Match control group cohorts to test group by change size (LOC + file count), author type (human vs. agent), and repo. A naive packet-vs-no-packet comparison drowns in variance because most of the time-to-approval signal is in change size.

### Timeline
Two weeks of qualitative dogfooding to tune the packet schema and prompt, then four weeks of quantitative measurement.

### Exit condition
If time-to-approval for packet PRs does not improve by at least 20% relative to matched controls in four weeks, we stop investing beyond MVP.

## Scope

For the MVP:
 - packet schema
 - render surface above the existing diff
 - CLI / skill support
 - per-reviewer check progress and hunk coverage (informational, no merge gating)
 - update delta between patchsets

**Explicitly out for MVP:** 
 - merge gating on hunk coverage
 - integration with external tools
 - multi-service cross-packet linking

**Cost estimate.** Two weeks of focused single-engineer work. The render surface and anchoring glue are the bulk of it; the thread infrastructure already exists.

## Risks

### Packet quality.
A bad packet is worse than no packet. If the agent flags the wrong invariants or buries the risky hunk in the middle of the tour, reviewers follow the packet away from what matters. Mitigation: manual review of the first 20 packets generated, with prompt iteration before the quantitative window opens.

### Section sprawl.
Six sections is the ceiling for a single artifact. There will be requests for performance impact, security review, API compatibility, and so on. A new section has to answer a distinct reviewer question that none of the existing six answer. That bar is high on purpose — a longer packet is not a better packet.

### Performative deploy plans.
Agents will write "ship behind a feature flag" on changes that do not need one. Empty sections are better than sections that look substantive but say nothing. The schema treats optional sections as suppressable; the prompt should say so explicitly.

## How to contribute

**Team leads** — nominate one agent-authored PR your team will dogfood. PRs over 300 lines that touch code outside the author primary area are the best candidates: that is where review drag is worst and where packets will have the most signal.

**Designers** — the hunk coverage visualization (which hunks has this reviewer actually read?) is open. See PRD section "Approved state" and open question 4.

**Platform engineers** — anchoring drift on force-push and rebase needs attention. See spec sections 6 and 12.

**Leadership** — sign off on the scope cuts above, and weigh in on whether merge gating belongs in MVP or a follow-on release.

## Future work

MVP keeps the coverage map informational. A few directions worth naming, though none are committed:

**Agentic reviews.** Add integration points for copilot and other platforms to engage with these artifacts (ideally in a way that's separate but compatible with the "bespoke" human review loops)

**Ownership-aware routing.** If the tour can tag hunks with the team that owns them, the review system can route approval requirements accordingly. One group approves their slice, another approves theirs, without either blocking the other. Most repos already have file-level ownership data that could serve as the routing source of truth. This would let specialists sign off on what they own without gating the whole PR on their availability.

**Signed merge commits.** The draft phase allows unsigned commits, which is fine for agents iterating quickly. An approved packet creates a natural gate: once all required reviewers sign off, the merge commit itself could be signed by the review platform rather than a personal key. That gives the commit history stronger auditability than individual signing keys and removes the need for every contributor to manage signing infrastructure locally. The tooling to do this exists and is reasonably mature.

**Deeper platform integrations.** The packet schema is structured data. Issue trackers, deployment systems, notification channels, and agentic workflows could all read it. A PR that closes a ticket could update the ticket on approval. A deployment system could parse the Deploy section directly rather than relying on the PR description. An agent doing a follow-up review could use the invariants section as a checklist. The review surface does not need to change for any of this — it is a matter of downstream consumers reading the packet.

## Open questions

1. Who owns the packet prompt and schema? Someone needs to be the named DRI for changes as the team learns what works.
2. Should agents generate packets for all PRs, or only above a size or complexity threshold?
3. How do we version the schema as sections evolve without breaking older packets?
4. What does the coverage map show for a reviewer who approved a packet from a previous patchset?

*Companion docs: PRD covers lifecycle, user stories, and flow diagrams. Spec covers schemas, anchoring, CLI integration, and the rendering boundary.*
