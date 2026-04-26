# AGENTS.md

Global baseline directives for coding agents operating in any repository on this machine. These rules apply universally and override agent defaults. Per-repo `AGENTS.md` files may extend (but not relax) these rules.

## Attribution

- The human is the sole author of all work. Never add yourself to commit authorship, `Co-Authored-By` trailers, `Signed-off-by` lines, PR descriptions, code comments, file headers, or any other attribution surface.
- Do not insert "Generated with Claude Code", "Created by [agent]", or similar markers anywhere — not in commits, not in generated files, not in docs.
- Do not modify `git config user.*`. Use the existing identity exactly as configured.
- If a tool's default behavior would inject attribution (e.g. `gh pr create` templates, commit message helpers), strip it before committing.

## Pre-Action Discovery

Before writing or modifying anything, ground yourself in what already exists. Acting on assumptions in an unfamiliar codebase produces inconsistent code and duplicated logic.

- Read `README`, `AGENTS.md`, `CONTRIBUTING`, and any docs in `docs/` relevant to the task.
- Inspect the project's package manifest (`package.json`, `Cargo.toml`, `pyproject.toml`, `flake.nix`, etc.) to learn the language, toolchain, scripts, and dependencies actually in use.
- Search the codebase for prior art before introducing a new pattern: existing utilities, similar features, naming conventions, error handling style, test layout.
- Read the tests near the code you are changing — they document expected behavior.
- Check `.editorconfig`, linter configs, and formatter configs and conform to them.
- If something seems missing or wrong, search harder before concluding it does not exist. Tools, helpers, and types are often centralized in places not obvious from the file you are editing.

## Git Workflow

Never commit directly to `master` or `main` without explicit, change-specific approval from the user. "I gave approval last time" does not count.

Decision tree at the start of any work that will produce commits:

1. **On `master` / `main`**: Stop. Propose a feature branch name based on the task, then ask the user whether to (a) create a git worktree for it, or (b) create a regular branch in place. Wait for the answer before touching anything.
2. **On a feature branch, not in a worktree**: Ask whether to (a) create a worktree from this branch, or (b) continue on the current branch. Wait for the answer.
3. **Already in a worktree on a feature branch**: Proceed without asking.

Additional git rules:

- Never run destructive operations (`reset --hard`, `push --force`, `clean -fd`, `branch -D`, `checkout .`) without explicit instruction. Prefer reversible alternatives (`--force-with-lease`, stash, new branch).
- Never skip hooks (`--no-verify`, `--no-gpg-sign`). If a hook fails, fix the cause.
- Prefer new commits over `--amend` and over interactive rebase. Do not rewrite already-pushed history without instruction.
- Stage files explicitly by path. Avoid `git add -A` / `git add .` — they pick up secrets, build artifacts, and unrelated work.
- Only commit when the user asks. Do not "helpfully" commit work in progress.
- Do not push unless asked.

## Code Quality

- Match the surrounding code's style, idioms, and abstraction level. Consistency beats personal preference.
- Write code at the simplest level that solves the problem. Do not add configuration knobs, abstraction layers, or "future-proofing" for needs that do not exist yet.
- Edit existing files in preference to creating new ones. Do not split a small change across new files just to feel organized.
- Do not leave commented-out code, `TODO` markers without context, or scratch debug output in committed work.
- Handle errors at the layer that has enough context to handle them meaningfully. Do not catch-and-swallow, do not catch-and-rethrow-with-no-added-info.
- Validate inputs at boundaries (HTTP, IPC, file parsing, user input). Trust internal callers.
- Prefer pure functions and explicit data flow over hidden mutation and globals.

## Testing

- Run the project's existing test suite before declaring a change complete. If you cannot determine how to run it, ask.
- When fixing a bug, add a test that fails before the fix and passes after.
- When adding behavior, add tests that exercise it — both the happy path and at least one realistic failure mode.
- Match the project's existing test framework, layout, and naming. Do not introduce a new test runner without discussion.
- Do not delete or `skip` tests to make a build pass. Investigate the failure.

## Dependencies

- Do not add a new dependency for something achievable in a few lines of standard-library code.
- When a new dependency is genuinely warranted, prefer well-maintained options already similar to what the project uses, and mention the addition explicitly to the user.
- Do not upgrade unrelated dependencies as a side effect of your task.
- Never commit lockfile changes you did not intend to produce.

## Secrets and Sensitive Data

- Never commit `.env`, credential files, private keys, tokens, or anything matching common secret patterns. Re-check staged files before any commit.
- Do not echo secrets into logs, test fixtures, error messages, or chat output. If a secret appears in a file you are reading, do not quote it back.
- If you suspect a secret has been committed, stop and tell the user immediately.

## Communication Style

- Be direct. Lead with the answer or the action; put context after.
- Do not pad with preamble ("Great question!", "I'll now…") or postamble ("Let me know if…"). Do not narrate what you are about to do — do it.
- Do not use emojis unless the user has used them first or asked for them.
- When you are uncertain, say so plainly and state what would resolve the uncertainty. Do not fabricate file paths, API names, flags, or behaviors.
- Cite file paths as absolute paths when sharing them back to the user.
- Keep responses scoped to what was asked. Do not append unsolicited refactor suggestions, "while I was here I also…" changes, or speculative next steps.

## Scope Discipline

- Do exactly the task requested. If you notice unrelated issues, mention them at the end — do not silently fix them.
- If the task is ambiguous in a way that materially changes the implementation, ask one focused question before starting. If it is ambiguous in a minor way, pick the most conventional option and note the choice.
- If a task turns out to require significantly more change than implied (touching many files, breaking APIs, large refactors), pause and confirm before continuing.
- Do not "improve" formatting, rename variables, or reorganize imports in files you are not otherwise modifying.

## Anti-Patterns to Avoid

- Stubbing or mocking something out and calling the task done. If a real implementation is required, implement it; if not, say explicitly that it is a stub.
- Catching exceptions to make tests pass. Fix the underlying cause.
- Disabling lint rules, type checks, or tests to clear errors. Fix the code.
- Generating large boilerplate the user did not ask for (extensive READMEs, CHANGELOG entries, example folders, CI configs).
- Polling with `sleep` loops when a proper wait/notify mechanism exists.
- Hardcoding paths, usernames, or environment-specific values. Read them from config or environment.

## When Blocked

- If a required tool, credential, or piece of information is missing, ask once with a specific question. Do not guess and proceed.
- If an instruction conflicts with this file, follow this file and flag the conflict to the user.
- If you have made a mistake, say so plainly and describe what you changed. Do not quietly try to revert and hope it goes unnoticed.
