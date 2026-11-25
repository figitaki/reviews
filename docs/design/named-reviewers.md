# Named reviewers

Status: draft for discussion. Issue [#214](https://github.com/figitaki/reviews/issues/214). No code yet.

## Problem

Only the review owner can approve, deny or ignore a packet section. `Reviews.Policy` has said so since #176, and it leaves a hook: "Explicitly added reviewers will also be allowed here once that feature exists." A teammate asked to review can comment, but cannot record a decision, so the owner records it for them and the history shows the wrong person.

This doc proposes how the owner names reviewers, what those reviewers may do, and how their decisions add up.

## What exists today

- **Decisions belong to an account.** `packet_section_decisions` is unique on `(review_id, patchset_id, account_id, section_index)`, and `author_id` records which identity set it. An account is a person (`users`, one GitHub user) and their agent identities. So the table already holds one decision per account per section; it just never holds more than the owner's.
- **Policy works on accounts.** `owner?/2` compares `owner_user_id`. A person's agents share their permissions.
- **Handles are not global.** A human identity's handle mirrors the GitHub login. Agent handles are unique only within one account (`identities_owner_lower_handle_index`), so `@codex` can name several agents.
- **Writes by surface.** REST and the CLI decide with `POST /api/v1/reviews/:slug/sections/:i/decision` and `reviews section`. The review page toggles. MCP has no decision tool, and `Policy.scoped?/2` refuses `:decide_section` to OAuth connectors because it has no scope.
- **Reads.** Open PR #286 (for #266) adds `selected_patchset.section_decisions` to the snapshot, `reviews show` and MCP `reviews_get_review`. Each section lists the decisions in effect, one per account, with author, `carried_forward` and `decided_at`.
- **Lists.** `Reviews.ReviewIndex` lists reviews a viewer wrote or took part in (comment, decision, viewed hunk). Nothing lists reviews someone was asked to look at.
- **Notifications.** None. There is no mailer; `users.email` is stored but unused.
- **Closed #82** (`carey/show-deciders-list`) has a read model, `Reviews.ReviewDeciders`, and a stack component, `ReviewsWeb.DeciderComponents`. It treats anyone with a decision or comment as a reviewer and rolls each account's sections into one badge. It was parked because only the owner could decide.

## Recommendation

**A reviewer is an account, named by GitHub login, added by the owner.** A reviewer's agents may decide for them, and each decision shows which identity made it. Every reviewer's decision is shown; the section and review states are a plain roll-up of all current reviewers, and nothing is gated on them yet.

### Who is a reviewer

A row in a new `review_reviewers` table:

| Column | Notes |
| --- | --- |
| `review_id` | Cascades with the review. |
| `user_id` | The reviewer's account; null until an invited person signs up. |
| `github_id` | GitHub's numeric user ID, resolved when the owner adds the login. Stable across renames. |
| `github_login` | The login as typed, for display while the invite is pending. |
| `added_by_id` | The identity that added the reviewer. |
| timestamps | |

Unique on `(review_id, github_id)`.

- **Named by GitHub login.** It is the only name that is global and that people already know. The human handle is the same login in nearly every case. Agent identities cannot be added on their own: their handles are not unique, and an agent always acts for an account anyway.
- **Invites before sign-up.** When the owner adds a login, the server looks up its GitHub ID with GitHub's public `GET /users/{login}` (Req is already a dependency). If an account with that `github_id` exists, `user_id` is set right away. Otherwise the row waits, and `Accounts.upsert_from_github/1` claims every pending row with that `github_id` on first sign-in. Matching on the ID, not the login, means a renamed or reused login cannot claim someone else's invite. An unknown login is a 422 `reviewer_not_found`.
- **The owner's account cannot be added.** It already decides as owner.

### Adding and removing

All four surfaces call one context, `Reviews.Reviewers` (`add/3`, `remove/3`, `list/1`), which checks a new `Policy` action `:manage_reviewers` (owner only).

| Surface | Add | Remove | List |
| --- | --- | --- | --- |
| Web | "Add reviewer" field in the reviewers popover on the review page (owner only) | remove button on each reviewer | the reviewers stack |
| REST | `PUT /api/v1/reviews/:slug/reviewers/:login` (idempotent) | `DELETE` the same path | `reviewers` in `GET /api/v1/reviews/:slug` |
| CLI | `reviews reviewers add <slug> <login>...`, and `reviews push --reviewer <login>` | `reviews reviewers remove <slug> <login>...` | `reviews reviewers <slug>`, and in `reviews show` |
| MCP | `reviews_update_reviewers` with `add` and `remove` lists, under the `reviews:write` scope | same tool | in `reviews_get_review` |

**Removing a reviewer** deletes the membership row only. Their decisions stay in `packet_section_decisions` and stay visible as history, marked as from a former reviewer, but they no longer count in the roll-up. Adding them again brings those decisions back under the usual carry-forward rules.

### Who may decide

`Policy.allowed?(_, :decide_section, review)` becomes owner **or** an account with a claimed `review_reviewers` row. `Review` preloads its reviewers where the page already preloads the author, so checking stays one query.

**A reviewer's agents may decide for them**, as the owner's agents do today. That follows from decisions being per account, and it is what makes "an agent reviews, the person signs off" work. The decision records the agent as `author`, and every surface shows "approved by @codex for @alice". If a review needs a person's own approval, that is verified approval (#59, #141), not this feature.

For MCP connectors, add a `sections:write` scope ("Decide packet sections") and a `reviews_set_section_decision` tool. Without the scope, connectors still cannot decide, as now.

### How decisions add up

Per section, for the selected patchset, using each account's effective decision (`PacketSectionDecisions.section_state/4`, so carry-forward and invalidation stay as they are):

| Section state | When |
| --- | --- |
| Denied | Any current reviewer denied it. |
| Approved | Every current reviewer approved or ignored it, and at least one approved. |
| Ignored | Every current reviewer ignored it. |
| In review, "1 of 3" | Otherwise. |

The review's overall state uses the same rule over sections: **Denied** if any section is denied, **Approved** if every section is approved or ignored, otherwise **In review** with a count of sections left. A review with no named reviewers keeps today's behaviour: the owner's decisions are the only ones and the roll-up uses them.

The owner's own decisions are shown beside the reviewers' as self-checks but do not count once reviewers exist. This is display only. Nothing blocks a push or a merge on it.

### Notifications

None in the first version. A reviewer finds the review in a **Requested** list on `/reviews` (and `reviews list --role requested`, `GET /api/v1/reviews?role=requested`), and the stack updates live over the existing `"review:<slug>"` PubSub topic. Email needs a mailer, sender setup and an unsubscribe path; it can follow once the Requested list shows whether people miss requests.

### The #82 reviewers row

**Reuse the component, replace the read model's membership rule.**

- Keep `DeciderComponents` and `deciders.css` (tokens, overflow chip, accessibility, the phone fixes) and the live-update broadcast.
- Rebase `ReviewDeciders` on named membership: every named reviewer is in the stack, even with no activity (badge "Pending"; "Invited" for an unclaimed invite). Accounts with only comments appear after them as "Commented", as #82 did. The owner is shown last, marked owner.
- Build the per-reviewer badge from #286's per-section decisions instead of #82's own query, so there is one roll-up, not two.
- Rename it the "reviewers stack" in code and UI, and put the owner's add/remove controls in its popover.

### Fit with #272 and #266

- **#272 (queued reviews).** This answers its first open question: a review is in your queue when you are a named reviewer and at least one section has no effective decision from your account on the latest patchset. A new patchset that changes a section puts it back in the queue by itself, because the carry-forward rule drops your decision. The Requested list in phase 2 is that queue's first form; #272 can add the ordering and "open at the first pending section".
- **#266 / #286 (agents reading decisions).** #286's shape already has room for several accounts per section. Phase 1 adds `selected_patchset.reviewers` (login, status `invited` or `active`, account handle) and, per section, `state` with the roll-up above, and marks each decision `reviewer`, `owner` or `former`. An authoring agent then waits for `state == "approved"` on every section rather than inspecting authors.

### Permissions summary

| Action | Owner | Named reviewer | Anyone signed in |
| --- | --- | --- | --- |
| Read, comment | yes | yes | yes |
| Decide a section | yes | yes (new) | no |
| Add or remove reviewers | yes | no | no |
| Push, delete | yes | no | no |
| Resolve or reopen a thread | yes | own threads | own threads |

Agents act with their account's row. MCP connectors also need the scope: `reviews:write` to manage reviewers, the new `sections:write` to decide.

### Migration

One additive migration creates `review_reviewers` with its indexes and foreign keys (`review_id` and `user_id` cascade; `added_by_id` nilifies). No backfill: no review has reviewers today, and `packet_section_decisions` needs no change. It rolls back by dropping the table. The `forbidden` message on the decision endpoint changes from "Only the review owner can decide sections" to "Only the review owner and its reviewers can decide sections"; the code stays `forbidden`.

## Phases

1. **Reviewers can decide.** Table, `Reviews.Reviewers`, invite claiming on sign-in, `Policy` changes, REST and CLI add/remove/list, `--reviewer` on push, reviewers and roll-up in the snapshot (on top of #286), owner controls on the review page. Docs in `CONTRACTS.md` and the skills.
2. **Reviewers stack and Requested list.** Port #82's stack onto membership; the Requested role in `ReviewIndex`, `/reviews`, the API and `reviews list`. This is the base for #272.
3. **MCP.** `reviews_update_reviewers`, the `sections:write` scope and `reviews_set_section_decision`, with docs in `MCP.md`.
4. **Later, if wanted.** Email on add, required approvals or quorum, a reviewer stepping down.

## Questions for Carey

1. **Combining.** Is "every current reviewer" the right roll-up, or is one approval enough? Should the owner's decision count once reviewers exist?
2. **Agents.** May a reviewer's agents decide for them, as proposed, or should reviewer decisions need the person (human identity) for now?
3. **Invites.** Is it fine to call GitHub's public user API when an owner adds a login, so invites match on GitHub ID? The alternative is matching on login text, which is simpler but lets a renamed or reused login claim the invite.
4. **Visibility.** Reviews are readable by anyone with the link. Is it fine that the reviewers list, including pending invite logins, is visible to them too?
5. **Reviewer rights.** Can a reviewer remove themselves, or add other reviewers? The proposal says no to both in phase 1.
6. **Notifications.** Is the Requested list enough for a first version, or is email on add needed before people will use it?
7. **Agent queues.** Should an agent token see its account's Requested list (`role=requested`), given that agent tokens today list only their own reviews?
