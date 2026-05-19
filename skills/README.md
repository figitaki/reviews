# Reviews Skills

Reviews includes repo-local skills for agents and custom AI orchestration
platforms. They teach an agent when to use Reviews, how to write review
packets, and how to run the local review workflow.

## Skills

- `reviews-overview` should be broadly available. It explains what Reviews is,
  when to use it, and how it fits before or alongside public pull requests.
- `writing-review-packets` should be available to agents that can inspect diffs
  and create review packet markdown.
- `using-reviews-locally` should be available to agents that can run local
  commands, mint or use API tokens, and push reviews from a checkout.

For most agent workspaces, make all three skills available together. The
overview skill helps choose the workflow, the packet skill structures the
human-facing review, and the local skill handles server and CLI operations.

## Release Install

The Reviews CLI installer can optionally install these skills after installing
the `reviews` binary:

```sh
curl -fsSL https://raw.githubusercontent.com/figitaki/reviews/main/install.sh | sh
```

By default, the installer prompts before installing skills. Non-interactive
installers can choose explicitly:

```sh
curl -fsSL https://raw.githubusercontent.com/figitaki/reviews/main/install.sh | sh -s -- --with-skills --yes
curl -fsSL https://raw.githubusercontent.com/figitaki/reviews/main/install.sh | sh -s -- --no-skills
```

Set `REVIEWS_SKILLS_DIR` to install into a custom harness directory:

```sh
REVIEWS_SKILLS_DIR="$HOME/.my-agent/skills" ./install.sh --with-skills
```

Use a colon-separated list to install into multiple custom destinations.

## Local Development Install

When developing the skills from this repo, use symlinks so edits are picked up
immediately:

```sh
mkdir -p "$HOME/.codex/skills"
ln -s "$PWD/skills/reviews-overview" "$HOME/.codex/skills/reviews-overview"
ln -s "$PWD/skills/writing-review-packets" "$HOME/.codex/skills/writing-review-packets"
ln -s "$PWD/skills/using-reviews-locally" "$HOME/.codex/skills/using-reviews-locally"
```

If a destination already exists, inspect it before replacing it.

## Custom Harness Integration

Custom agent platforms should preserve each skill directory as a unit:

- Load the `SKILL.md` frontmatter to decide when the skill should be available.
- Load the `SKILL.md` body only when the skill triggers.
- Preserve relative paths inside each skill directory.
- Optionally read `agents/openai.yaml` for display name, short description, and
  default prompt metadata.

Skills should be treated as instructions, not as executable plugins. The agent
is still responsible for choosing tools, requesting permissions, and reporting
results according to its host platform.

## Suggested Workflows

- After a few turns of agent-driven implementation, use `reviews-overview` to
  decide whether a Reviews link is the right review surface.
- Use `writing-review-packets` to organize the diff into reviewable sections
  with prose and hunk references.
- Use `using-reviews-locally` when the agent should start a local server,
  configure a local token, or push a new review or patchset.
