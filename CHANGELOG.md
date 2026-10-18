# Changelog

## [1.2.0] - 2026-10-18

- Add a `.pre-commit-hooks.yaml` manifest, so the four hooks install through the pre-commit framework (`ai-review`, `ai-commit-message`, `commit-msg-validate`, `secret-scan`). Under pre-commit, the pre-push scan reads its range from `PRE_COMMIT_FROM_REF` / `PRE_COMMIT_TO_REF`, or scans the whole branch from `PRE_COMMIT_LOCAL_BRANCH` when the push includes the root commit, and prepare-commit-msg reads `PRE_COMMIT_COMMIT_MSG_SOURCE`, so `git commit -m` messages are left alone. Checked end to end with pre-commit 4.7.0: a bad message is rejected, and both a first push and a new-branch push with a key are blocked
- Add `scripts/get.sh`, a one-line installer: `curl -fsSL .../scripts/get.sh | bash` clones or updates `~/.ai-git-hooks` and runs `install.sh` for the current project. It refuses to run outside a git repository before cloning anything
- Add `scripts/benchmark.sh` and [docs/benchmark.md](docs/benchmark.md): the pre-push scan and gitleaks scored on the leaky-repo corpus with leaky-repo's own method, plus a noise check on express, requests, flask and react-hook-form at pinned tags
- Widen the secret patterns from 31 to 40, driven by that benchmark, which took the scan from 5 to 34 of 175 corpus lines (21 of 44 files, 0 false positives). Quoted `password` / `secret` / `api_key` / token values now match with `:` as well as `=` and with a quoted key, so JSON and YAML configs are scanned. New rules: PEM private keys of any type, PuTTY keys, credentials in http/ftp/smtp/imap/amqp URLs, npm `_authToken` and `_auth`, Docker registry `auth`, `.netrc` logins, Laravel `APP_KEY`, crypt and bcrypt password hashes, and `oauth_token`. URL and `.netrc` passwords need 6+ characters and the npm keys must start a line, which cut the noise on requests from 31 findings to 10
- Report every secret finding as `file:line`, with the line number in the pushed file. Before, the scan printed only the pattern name and the masked line
- Fix the pre-push scan skipping files with non-ASCII names. git listed them as quoted octal escapes, which then matched nothing as a pathspec, so a key in a file named with an accented or CJK character passed with "All checks passed". The file lists are now read with `core.quotePath=false`
- Measure large files from the pushed blob (`git cat-file -s`) instead of the working-tree copy, which sized the wrong content when pushing another branch and skipped files deleted locally
- Fix the pre-commit review passing a reply that listed `ERROR` lines and also contained `NO_ISSUES`. It now counts as clean only when no finding line is present
- Add `AI_HOOKS_MOCK_RESPONSE`, which replaces the dry-run stand-in reply so the test suite can feed the review parser real findings
- Add `scripts/demo.sh`, which runs the hooks in a throwaway repo in dry-run mode, and an animated terminal demo in the README rendered from its output
- Add 21 tests (47 to 68): the first-push and new-branch pre-push paths, `sk-proj-` keys, `file:line` reporting, non-ASCII file names, blob-size measurement, both pre-commit framework ranges, the new patterns and their look-alikes, the review parser on findings, the `PRE_COMMIT_COMMIT_MSG_SOURCE` skip, `get.sh`, and the manifest entries. CI now also validates the manifest and runs the demo
- README: a Why this one section, the three install paths, the real pre-push output with `file:line`, the full pattern list, and the benchmark headline

## [1.1.0] - 2026-10-18

- Fix the pre-push scan passing the first push of a repo with a secret in it. A new branch with no upstream got the range `<sha>~10..<sha>`, which does not exist in a repo with fewer than 11 commits, so `git diff` failed silently, nothing was scanned and the hook printed "All checks passed". On longer histories it scanned the last 10 commits of `HEAD` rather than the branch being pushed. The range now starts where the pushed commits leave remote history, or at the empty tree when nothing is on a remote yet
- Detect current OpenAI keys (`sk-proj-`, `sk-svcacct-`, `sk-admin-`). They contain `-` and `_`, so the legacy `sk-[a-zA-Z0-9]{20,}` pattern never matched them
- Fix the pre-commit hook blocking the commit with no explanation when the API key is missing or the provider returns an error. Its messages went to stdout inside `$(...)` and were captured as the response; they now go to stderr, as in `prepare-commit-msg`
- Fix `install.sh` and `uninstall.sh` in linked worktrees and submodules (where `.git` is a file) and with `core.hooksPath` set. The hooks directory now comes from `git rev-parse --git-path hooks`, and `.ai-hooks.yml` is created at the repo root even when the installer runs from a subdirectory
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
