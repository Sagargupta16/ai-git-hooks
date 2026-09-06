# Changelog

## [1.1.0] - 2026-09-06

- Fix shell scripts shipping without the executable bit, so `./scripts/install.sh` works in a fresh clone
- Fix the two default-enabled message hooks rejecting each other: the validator now accepts the `PROJ-42: feat: ...` ticket prefix that the generator writes
- Fix `hooks.pre-push.ignore` being read but never applied, so a false positive in a doc or fixture now has an escape hatch
- Fix `hooks.commit-msg.allowed_types` being silently ignored (the config lookup matched the wrong hook block)
- Read `ollama.host` from config instead of only the `OLLAMA_HOST` environment variable
- Remove `custom_patterns` from the example config: it was documented but wired to nothing
- Correct the README install steps, which installed the hooks into the ai-git-hooks clone rather than your project
- Correct the Ollama switch instructions, which told you to append config keys that the reader ignores
- Document requirements (`jq` is mandatory), the per-commit request pattern, and troubleshooting
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
