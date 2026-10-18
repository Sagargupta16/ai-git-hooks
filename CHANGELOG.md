# Changelog

## [1.1.0] - 2026-10-18

- Fix the pre-push scan passing the first push of a repo with a secret in it. A new branch with no upstream got the range `<sha>~10..<sha>`, which does not exist in a repo with fewer than 11 commits, so `git diff` failed silently, nothing was scanned and the hook printed "All checks passed". On longer histories it scanned the last 10 commits of `HEAD` rather than the branch being pushed. The range now starts where the pushed commits leave remote history, or at the empty tree when nothing is on a remote yet
- Detect current OpenAI keys (`sk-proj-`, `sk-svcacct-`, `sk-admin-`). They contain `-` and `_`, so the legacy `sk-[a-zA-Z0-9]{20,}` pattern never matched them
- Fix the pre-commit hook blocking the commit with no explanation when the API key is missing or the provider returns an error. Its messages went to stdout inside `$(...)` and were captured as the response; they now go to stderr, as in `prepare-commit-msg`
- Fix `install.sh` and `uninstall.sh` in linked worktrees and submodules (where `.git` is a file) and with `core.hooksPath` set (husky and similar). The hooks directory now comes from `git rev-parse --git-path hooks`, and `.ai-hooks.yml` is created at the repo root even when the installer runs from a subdirectory
- Report a missing `jq` as an error in the installer, matching the README: the pre-commit hook blocks commits without it
- Correct the README example output for all three blocking hooks to what the hooks actually print, and the pre-commit `severity` default to `error`, which is what ships. The commit-msg example claimed a "message too vague" check that does not exist
- Correct the example config comment on `hooks.pre-commit.ignore`: it decides whether the review runs, it does not remove files from the diff that is sent
- Add a How It Works section with an architecture diagram and the design decisions behind the hooks, and a CI badge
- Fix shell scripts shipping without the executable bit, so `./scripts/install.sh` works in a fresh clone
- Fix the two default-enabled message hooks rejecting each other: the validator now accepts the `PROJ-42: feat: ...` ticket prefix that the generator writes, and the generator spends the prefix out of the same `max_length` budget the validator enforces
- Fix the ticket prefix letting a commit skip the lowercase-description rule that an unprefixed commit has to obey
- Fix the GitHub-issue ticket prefix destroying the commit message. A `fix/gh-456-something` branch produced the subject `#456: feat: ...`, and a leading hash is a comment: git strips it under its default cleanup and the validator's `read_commit_message` drops every `^#` line, so the generated message was deleted and the commit failed with nothing to explain it. The prefix is now `GH-456`, which needs no new validator pattern because it already matches the Jira/Linear alternative. The unreachable `#[0-9]+` alternative is gone from `ticket_re`
- Fix the validator exiting silently on a message that is entirely comments. `grep -v '^#'` returns 1 when it selects nothing, and under `set -euo pipefail` that aborted the hook before `main()` could reach its "Commit message is empty." branch, so the user saw only the banner and a non-zero status
- Fix `hooks.pre-push.ignore` being read but never applied, so a false positive in a doc or fixture now has an escape hatch. The shipped list is empty: adding a pattern is opt-in, because listed files are not scanned at all
- Fix `hooks.commit-msg.allowed_types` being silently ignored (the config lookup matched the wrong hook block)
- Fix the pre-commit hook aborting with "IGNORE_PATTERNS[@]: unbound variable" on bash 3.2 (macOS system bash) when the project has no `.ai-hooks.yml`
- Read `ollama.host` from config instead of only the `OLLAMA_HOST` environment variable
- Remove `custom_patterns` from the example config: it was documented but wired to nothing
- Correct the README install steps, which installed the hooks into the ai-git-hooks clone rather than your project
- Correct the Ollama switch instructions, which told you to append config keys that the reader ignores
- Document requirements (`jq` is mandatory), the per-commit request pattern, and troubleshooting
- Derive the CI lint and executable-bit checks from a file scan, so adding a hook cannot skip them
- Drop `bin`, `engines`, `files` and `os` from `package.json`: the package is not published to npm, so they described a distribution that does not exist
- Delete `.nvmrc`, `.python-version`, `.prettierrc` and `.maintenance`: they pin toolchains for languages this repo does not contain, and nothing reads them
- Restore ShellCheck CI, failing since 2026-05-10 (#44)
- Fix stale model IDs and config keys the hooks silently ignored (#45)
- Restore `AI_HOOKS_DEBUG` verbose mode (#47)
- Fix four pre-push hook bugs, including a quote-handling bug that meant single-quoted secrets were never matched (#48)
- Default the Claude provider to Sonnet 5 (#49)

## [1.0.0] - 2026-03-16

- Add PR template, fix editorconfig and Code of Conduct
- Update LICENSE

## [0.1.0] - 2026-03-04

- Initial release: AI-powered git hooks
- Support for Claude, OpenAI, and Ollama
- Auto-review diffs, generate commit messages, security scanning
