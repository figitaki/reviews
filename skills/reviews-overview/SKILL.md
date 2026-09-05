---
name: reviews-overview
description: "Explain the Reviews platform to a general agent: what Reviews provides, when to use it during human-in-the-loop or agent-driven development, how review packets structure a diff for humans, and how Reviews can precede public PR creation or integrate with other review processes. Use when an agent needs to decide whether Reviews is the right tool, describe the platform, or orient a workflow around review packets and patchsets."
---

# Reviews Overview

Use this skill to understand Reviews as a code-review platform and decide when to use it in an agent workflow. This is not a repo implementation guide.

## What Reviews Is

Reviews is a review tool for arbitrary code diffs, not only GitHub pull requests. It lets an agent or developer push a diff to a shareable review URL, optionally attach a structured review packet, and iterate through revisions as patchsets.

The core value is making a diff understandable to a human reviewer before, during, or outside a public PR process.

## What Reviews Provides

- **Link-based review pages** for uploaded diffs.
- **Patchsets** for iterating on the same review as the work changes.
- **Review packets** that organize a diff into human-readable sections with prose and hunk references.
- **Lazy hunk rendering** so large diffs can be reviewed without eagerly mounting every diff.
- **Explicit hunk viewed state** for signed-in reviewers.
- **Section decisions** such as approve, deny, or ignore for packet sections.
- **Published review threads** that can be replied to, resolved, and reopened.
- **Changes view** for direct file/hunk review outside the packet narrative.

## When To Use Reviews

Use Reviews after a few turns of human-in-the-loop or agent-driven development when there is a coherent diff ready for human review.

Good moments:
- The agent has implemented a feature and wants a human to inspect the result before public PR creation.
- The user asks for a review packet, local review, or shareable review link.
- The work has grown large enough that raw `git diff` is hard to review.
- The agent wants to explain the review order, risk areas, and tradeoffs alongside the code.
- The team wants a pre-PR review pass before committing to a public GitHub PR.
- A project has another review process, but Reviews can provide the structured packet and hunk progress layer.

Avoid using Reviews when:
- There is no concrete diff yet.
- The user only wants brainstorming or planning.
- The change is tiny enough that inline explanation is sufficient.
- The diff contains secrets or local-only artifacts that should not be uploaded.

## How It Fits A Development Loop

Typical flow:

1. Develop with the user or autonomous agent loop.
2. Stabilize the diff enough for review.
3. Write or update a review packet that groups the work logically.
4. Push the diff and packet to Reviews.
5. Share the review URL with the human reviewer.
6. Address feedback.
7. Push another patchset to the same review.
8. Optionally create or update a public PR after review confidence is higher.

Reviews can be the review surface of record, or it can be an intermediate review artifact before another system such as GitHub PRs.

## Important Terms

- **Review**: the durable review URL and container for one line of work.
- **Patchset**: one revision of the uploaded diff within a review.
- **Review packet**: a markdown or JSON guide that describes how to review the diff.
- **Section**: a packet `##` grouping with prose and hunk references.
- **Hunk reference**: a pointer such as `@hunk path/to/file.ex#2` or a slice like `@hunk path/to/file.ex#2:L3-L18`.
- **Viewed hunk**: explicit reviewer progress; opening a hunk is not the same as marking it viewed.
- **Section decision**: explicit approve/deny/ignore state for a packet section.
- **Thread**: an inline conversation anchored to a diff line or token range.
- **Resolved thread**: a thread marked handled by a signed-in user. It remains visible inline with status, but is omitted from the Open threads sidebar.

## Agent Guidance

When using Reviews, prefer producing a packet rather than uploading a raw diff alone for substantial work. The packet should tell the human what to review first, why the sections exist, and where tradeoffs or risk live.

When updating a review, preserve packet section titles and hunk groupings if the goal is to keep previous section approvals valid. Create a new packet structure when the review framing has changed enough that prior approvals should not carry forward.

When addressing feedback from Reviews, list threads with `reviews threads <slug>` or inspect `reviews show --format md`, then mark completed feedback with `reviews resolve <slug> <thread-id>`. Use `reviews reopen <slug> <thread-id>` when a resolved thread needs attention again.

When reporting a Reviews link back to the user, include the URL and the patchset number if the CLI provides one.
