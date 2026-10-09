# Code review market scan (April–October 2026)

Research notes gathered 2026-10-09 for Reviews. Each row cites a primary
source where one was readable; "(search summary)" means only a search snippet
was seen, and "[unverified]" means the claim could not be confirmed.

## Products

| Product | What it is | When | Most relevant to Reviews | Link |
|---|---|---|---|---|
| Linear Diffs / Reviews | Reviews GitHub PRs inside Linear; reviews sync back to GitHub | Diffs launched 2026-05-28; Guided Reviews GA 07-30; stacked PRs + live diffs 10-08 | Guide tab: AI-generated sections, each with a short "why" and the related diffs; core change first, then consequences, then glue. Incremental guide updates; stale guides refresh after a PR update. Agents: "on behalf of" attribution (Claude Code, Codex, Pi, OpenCode); agent/bot comments grouped; 4-level risk score with explanation; `linear:extension` metadata in PR HTML comments. Files grouped via `.gitattributes` categories; line counts exclude tests and docs. Reviews still submitted at the PR level. | https://linear.app/docs/diffs · https://linear.app/changelog/2026-05-27-linear-diffs · https://linear.app/now/code-review-should-be-fast |
| Graphite (Cursor) | Stacked PRs, AI reviewer, merge queue | Acquired by Cursor 2025-12-19; Code Tours 2026-04-01 | Code Tours: a structured readout built from PR description, threads, stack and code, narrative next to the diff in sequence. Planned: visual artifacts and test validation (which tests verified the change). Unknown whether authors can edit a tour. | https://graphite.com/blog/code-tours |
| Cursor Origin | Git forge + code review aimed at agents, built by the Graphite team | Shown 2026-06-16; early beta 08-17 [unverified] | Direction to watch; details unpublished. | https://www.eesel.ai/blog/what-is-cursor-origin |
| CodeRabbit Change Stack | Guided review UI | 2026-05-13; Bitbucket + review history 07-20 | Diff split into independent cohorts, each into ordered layers tied to line ranges, each with a summary and sometimes a diagram. J/K navigation, per-file viewed state. Snapshots of the PR; shows when the view is stale and which commit it was built from. | https://www.coderabbit.ai/blog/introducing-atlas-the-first-ai-native-code-review-interface |
| Devin Review | Free review UI for GitHub PRs | 2026-01 | Groups changes logically with a description per group; detects moved/copied code; severity-tagged flags; `npx devin-review`. | https://app.devin.ai/review |
| GitHub | Copilot code review; native stacked PRs | Severity labels 05-12; agent PRs reviewable + resolution reasons 08-27; Copilot approval 09-01; improved review GA 09-18; stacks GA 10-06 | Overview sorts findings into open / resolved since last review / previously missed. Reviewers give a reason when resolving. Stacks keep approvals across a rebase when nothing else changed. `gh stack` supports worktrees. Agent-PR guide: require a failing test, treat CI weakening as a blocker, check the plan first. | https://github.blog/changelog/2026-09-18-copilot-code-review-an-improved-review-experience/ · https://github.blog/changelog/2026-10-06-stacked-pull-requests-generally-available/ · https://github.blog/ai-and-ml/generative-ai/agent-pull-requests-are-everywhere-heres-how-to-review-them/ |
| Greptile | AI reviewer | v4 03; Model Inversion 07-22; v5 08-05; new summaries 09-16 | Model Inversion: detects agent-written PRs and reviews with a different model. Summary opens with confidence + verdict; unresolved findings stay in the summary until threads resolve; "What we checked" when nothing found. | https://www.greptile.com/changelog |
| Claude Code Review / Cursor Bugbot / Ellipsis / Amp | AI bug finders | 2026 | Several agents per PR plus a verification pass (Claude). Bugbot has pre-PR `/review`. Bug finders, not review UIs. | https://claude.com/blog/code-review · https://cursor.com/blog/bugbot-updates-june-2026 |
| Pierre | `@pierre/diffs`, Trees, DiffsHub, Code Storage | DiffsHub ~2026-05 [unverified]; Code Storage private beta | Diffs has an annotation framework and line selection; review workflow is built on top. Code Storage: "no review primitives". | https://cdn.jsdelivr.net/npm/@pierre/diffs@1.5.1/README.md · https://news.ycombinator.com/item?id=47016562 |
| Gerrit 3.14 | Patchset-based review | 3.14.4 on 2026-09-23 | "Review Agent" chat panel with pluggable LLM providers. Robot comments removed in 3.13 in favour of the Checks API. | https://www.gerritcodereview.com/3.14.html |
| GitLab 19.x | Duo Code Review Flow | 19.0 2026-05; 19.5 GA | Duo can approve/request changes but its approval does not count toward required approvals. YAML exclusions for bot MRs. Agent can split oversized MRs. | https://docs.gitlab.com/user/duo_agent_platform/flows/foundational_flows/code_review/ |
| Reviewable | GitHub review overlay | Releases through 2026-09-21 | Immutable revisions; diff bounds (r3); review complete when all files marked reviewed at the latest revision and discussions resolved; custom completion conditions; "Pondering" draft disposition. | https://docs.reviewable.io/reviews |
| Tangled | Git forge on atproto | Pulls post 2025 | Immutable rounds: the author picks when to resubmit; reviews attach to a round. Stacks via jj change-ids. | https://blog.tangled.org/pulls/ |
| Radicle 1.10 / Forgejo 16 | P2P forge / self-hosted forge | 2026-08-05 / 2026-07-16 | Radicle: parent/child links between revisions. Forgejo: multi-line comments; reverse blame to keep comments placed as code changes. | https://radicle.dev/2026/08/05/radicle-1.10.0 · https://forgejo.org/2026-07-release-v16-0/ |
| Plannotator | Local diff/plan annotator that feeds an agent | 2026 | AI guided-review chapters with reviewed state per section; "Send Feedback" exports markdown anchored to files/lines into the agent session; local API where agents and CI post findings tagged by source. | https://plannotator.ai/code-review/ |
| Narrated Diffs | Author reorders chunks and adds comments | Prototype | Closest older match to an author-written packet; unfinished. | https://github.com/tbroadley/narrated-diffs |
| Markdown review tools | markdown-pr-review, Markdown Rich Review, DraftView, markupmarkdown | 2026, small | Comment on the rendered view, anchored to raw line ranges. DraftView syncs suggestions back as GitHub suggested changes. | https://github.com/abeltrano/markdown-pr-review · https://github.com/orgs/community/discussions/186730 |
| Jane Street Iron, Google Critique, ReviewStack | Older in-house tools | Pre-2024 | Iron: per-file scrutiny. Critique: 7.5% of comments resolved via ML-suggested edits. | https://blog.janestreet.com/code-review-that-isnt-boring/ |

Not found or not checked: CodeApprove, Crocodile, Phorge, git-appraise, CodeTour.

## Ideas worth borrowing

1. Section order convention (Linear, Plannotator, CodeRabbit) → packet layout. Core change, then consequences, then glue. Make it the default packet template; have the writing-review-packets skill warn on departures. S
2. Stale packet and coverage banner (CodeRabbit) → patchsets. "Packet written for patchset N"; flag sections whose hunk hashes no longer match; list uncovered hunks. S
3. Carry approvals forward on unchanged content (GitHub stacks, Reviewable) → decisions. Keep a section's approve when its hunk hashes did not change; reset only changed sections. M
4. Finding states across revisions (Copilot, Greptile) → threads. Open / resolved since last patchset / new; pin unresolved in the summary; require a resolution reason. S–M
5. Agent metadata: risk score and "on behalf of" (Linear) → agent identities. Per-section risk level + explanation; record the human the agent acts for. S
6. Record the authoring model (Greptile Model Inversion) → CLI. `reviews push` records the model that wrote the patchset so a reviewing agent can pick a different one. S
7. Feedback export for the authoring agent (Plannotator) → CLI. `reviews feedback <id>` prints open threads as markdown anchored to files/lines; accept findings from CI/linters tagged by source. S–M
8. File categories (Linear `.gitattributes`) → packet layout. Auto-collapse generated/lockfile hunks; separate implementation line count; group agent-guidance files. S
9. Verification section type (Graphite planned; GitHub agent-PR guide) → packet layout. Links tests proving each claim, spec-vs-diff checklist, CI weakening flagged. M
10. Rendered-view comments anchored to source (markdown-pr-review, DraftView) → document mode. Anchors = source range + content hash; suggestions as patches. M–L
11. Author-controlled rounds (Tangled) → patchsets. Keep "patchset only on explicit push" and make it visible. S
12. Approvals that do not count (GitLab 19.5) → consensus. Agent decisions shown but excluded from quorum unless policy allows. S

## Where Reviews is different

- The author writes the narrative and it is versioned. Linear, Graphite, CodeRabbit and Devin generate guides server-side; none document author editing.
- Decisions per section. Linear, CodeRabbit and GitHub use one PR-level review.
- Content-hash anchoring across Gerrit-style patchsets, outside GitHub. GitHub-overlay tools inherit GitHub's anchoring limits.
- Agents as named authors and reviewers in a self-hosted tool, usable before a PR exists.
- Gaps: no built-in AI bug finder (crowded space); no stacks or merge queue while GitHub stacks are GA; Linear's guide updates incrementally; Graphite/Cursor Origin may ship guided review on its own forge.
