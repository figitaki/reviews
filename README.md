# Reviews

**Code review that explains the change before you read it.**

Reviews turns any diff into a guided review. You get one link, and the author's
notes walk you through the change in the order that makes sense, right next to
the code. Comment on any line, approve the change one section at a time, and
come back to the same link when the author pushes an update.

**Try it now:** open the [demo review](https://reviews.figitaki.dev/r/demo-review),
or start your own at <https://reviews.figitaki.dev>.

## What you get as a reviewer

- **A guided read, not a wall of diff.** The author splits the change into
  sections and explains each one beside its code. The plain file-by-file view is
  one click away when you want it.
- **Decisions you can keep track of.** Approve, deny, or skip each section.
  Your decisions stay in place when the author pushes an update, unless that
  section changed.
- **Comments that keep up with the code.** Comments appear for everyone as
  soon as you post them, follow their lines into later updates, and can be
  replied to, resolved, and reopened.
- **Any change, not only pull requests.** A branch, a few commits, or work
  that isn't committed yet can all be reviewed, before there is a pull request
  or without one.
- **Agents you can tell apart.** Coding agents push, comment, and approve under
  their own names, never yours. Agents that connect through the
  [Personal Agent Protocol](https://personalagentprotocol.org/docs/1.0/spec)
  (Poppy) need their owner's approval, and their comments carry a
  "Verified agent" label that shows what Reviews checked and what the agent
  only says about itself.

Anyone with a link can read a review. To comment or decide, sign in with
GitHub.

## Start a review

You need a GitHub account and a Git checkout on macOS or Linux.

1. **Install the CLI.**

   ```sh
   curl -fsSL https://raw.githubusercontent.com/figitaki/reviews/main/install.sh | sh
   ```

2. **Connect it to your account.** Sign in at
   <https://reviews.figitaki.dev>, create a token in
   [Settings](https://reviews.figitaki.dev/settings), and run `reviews login`.
   Press Enter to use the hosted service, then paste the token.

3. **Push a change.** From your checkout, run:

   ```sh
   reviews push --title "Review my change"
   ```

   You get a link to share. After more edits, run
   `reviews push --update <slug>` to update the same review.

By default `reviews push` sends your last commit. Add `--range main..HEAD` for
a whole branch or `--range HEAD` for uncommitted work.

## Write the guide

The guide reviewers read is a short Markdown file called a review packet. Add
it with `--packet packet.md`, and run `reviews push --dry-run --packet
packet.md` first to check it without sending anything.
[Writing review packets](skills/writing-review-packets/SKILL.md) explains the
format, with an example.

## Let your agent do it

When you install the CLI, you can also add the Reviews skills for your coding
agent. With them, the agent can write the guide, push the review, and answer
comments. Give it its own token in Settings so its work shows under its own
name. Setup for Codex, Claude Code, and other agents is in
[`skills/README.md`](skills/README.md).

## Learn more

- [Writing review packets](skills/writing-review-packets/SKILL.md)
- [Agent skills](skills/README.md)
- [Verified agents with Poppy](docs/POPPY.md)
- [What's in 0.0.1](docs/RELEASE_0.0.1.md) and the [changelog](CHANGELOG.md)
- [All CLI releases](https://github.com/figitaki/reviews/releases)

Want to run Reviews yourself or contribute? See
[`CONTRIBUTING.md`](CONTRIBUTING.md).
