# Agent Instructions (OpenCode)

Default instructions for OpenCode when working on long robotics-software tasks
against the local `qwen-local` model. **This is a template.** Copy or adapt it
into the root of a target project so OpenCode picks up project-specific rules
(OpenCode reads `AGENTS.md` from the project root, then falls back to the
global `~/.config/opencode/AGENTS.md`).

## Before you edit

- Read any existing repo instructions first (`AGENTS.md`, `CLAUDE.md`,
  `README.md`, build files) and follow them over these defaults.
- For multi-stage work, state a short plan before changing files.
- Work on a dedicated Git branch or worktree per long task so progress is
  isolable and resumable.

## Code quality

- Use strict typing where the language supports it.
- Preserve reproducibility and pinned dependencies; do not bump versions
  unless asked.
- Make the minimal change that solves the problem; avoid drive-by refactors.

## Verification

- After each meaningful change, run the targeted tests (not the whole suite
  unless asked).
- Keep the repository in a resumable state: it should build and the relevant
  tests should pass at every milestone.

## Context discipline (keep the model's context small)

- Never print entire large files or full logs into the conversation.
- Redirect verbose command output to a file and inspect only a bounded
  excerpt, e.g.:
  - `build ... > artifacts/logs/build.log 2>&1; tail -n 40 artifacts/logs/build.log`
- Never print binary data, Base64 blobs, generated bundles, lockfiles, or large
  logs into context.
- Use timeouts for commands expected to terminate; avoid polling loops.

## Long-task recovery (do not lose the thread)

Maintain `AGENT_PROGRESS.md` at the project root during long work. After every
completed milestone:

1. Run the relevant tests.
2. Update `AGENT_PROGRESS.md` with: completed work, test results, blockers, and
   the exact next action.
3. Store verbose logs in the workspace (e.g. `artifacts/logs/`) and inspect
   only bounded excerpts.
4. Keep the repository in a resumable state.
5. Do not commit unless explicitly requested.

Do not rely on conversation history as the sole record of progress — the file
is the source of truth, so a restarted session can resume from it.
