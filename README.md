# AI Git Hooks

[![Test Hooks](https://github.com/Sagargupta16/ai-git-hooks/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/Sagargupta16/ai-git-hooks/actions/workflows/test.yml)
![GitHub stars](https://img.shields.io/github/stars/Sagargupta16/ai-git-hooks?style=flat-square&cacheSeconds=86400)
![GitHub forks](https://img.shields.io/github/forks/Sagargupta16/ai-git-hooks?style=flat-square&cacheSeconds=86400)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)
![Last Commit](https://img.shields.io/github/last-commit/Sagargupta16/ai-git-hooks?style=flat-square&cacheSeconds=86400)

> AI-powered git hooks that review your code, generate commit messages, catch bugs, and scan for security issues - before you push.

Drop-in git hooks that use AI (Claude, OpenAI, Ollama) to automate code quality checks at every stage of your git workflow.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/demo/demo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/demo/demo-light.svg">
  <img alt="Terminal demo: a vague commit message is rejected, a plain git commit gets a generated conventional message, and a push carrying an AWS key is blocked at config.js:3" src="docs/demo/demo-dark.svg" width="100%">
</picture>

The output above is from [`scripts/demo.sh`](scripts/demo.sh), which runs the
real hooks in a throwaway repo with no API key. It runs in dry-run mode, so the
review and the generated message are the fixed stand-in replies; the validator
and the secret scan make no AI call and print exactly what a real run prints.
Try it: `git clone https://github.com/Sagargupta16/ai-git-hooks.git && ./ai-git-hooks/scripts/demo.sh`.

## Why this one

- **One install, four gates.** Review, message, message validation and a secret
  scan, from a single clone, one installer or one `.pre-commit-config.yaml`.
- **No runtime to install.** Bash, `git`, `curl` and `jq`. No Node, no Python,
  no daemon.
- **The blocking push gate is not AI.** The secret scan is regex, so it gives
  the same answer every time, and it is measured: see the
  [benchmark](docs/benchmark.md).
- **Local models work.** Point it at Ollama and no diff leaves your machine.

## Hooks

| Hook | Description | Trigger |
|------|-------------|---------|
| [AI Code Review](hooks/pre-commit/) | Reviews staged changes for bugs, style issues, and anti-patterns | `pre-commit` |
| [Commit Message Generator](hooks/prepare-commit-msg/) | Auto-generates conventional commit messages from your diff | `prepare-commit-msg` |
| [Commit Message Validator](hooks/commit-msg/) | Validates commit messages follow conventions | `commit-msg` |
| [Pre-Push Security Scan](hooks/pre-push/) | Scans for secrets, vulnerabilities, and large files | `pre-push` |

## How It Works

Each hook is a standalone Bash script. There is no daemon, no package and no
runtime beyond `git`, `curl` and `jq`: the installer copies the four scripts into
the hooks directory git reports for your project, and git runs them.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/hook-flow-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/diagrams/hook-flow-light.svg">
  <img width="880" src="docs/diagrams/hook-flow-light.svg" alt="Flowchart of what runs on git commit and git push. git commit runs the pre-commit review of the staged diff, and a blocking finding stops the commit. Otherwise prepare-commit-msg writes the message, skipped on git commit -m, and commit-msg validates it with rules: an invalid message is rejected and a valid one becomes the commit. The review and the message generator send the diff to the one provider set in .ai-hooks.yml, Claude at api.anthropic.com, OpenAI at api.openai.com or Ollama at localhost:11434, and commit-msg asks it for a suggested fix only when validation fails. git push runs the pre-push scan, which calls no model: 40 regex secret patterns, a file size check that warns over 5 MB, and npm audit or pip-audit. A critical finding blocks the push; otherwise the push proceeds.">
</picture>

The spec behind the picture is [`docs/diagrams/hook-flow.yaml`](docs/diagrams/hook-flow.yaml), rendered with [orrery](https://github.com/Sagargupta16/orrery).

Design decisions worth knowing:

- **The secret scan is deterministic.** `pre-push` makes no AI call. A model can
  miss a key or hallucinate one, so blocking a push is left to regex patterns
  that behave the same on every run.
- **The model gets a line protocol, not free text.** The review prompt asks for
  `SEVERITY|FILE:LINE|DESCRIPTION|SUGGESTION` lines or `NO_ISSUES`, which the
  hook parses into counts and compares against `severity` to decide whether the
  commit is blocked.
- **The generator and the validator agree.** `prepare-commit-msg` spends the
  ticket prefix (`PROJ-42: `) out of the same `max_length` budget that
  `commit-msg` enforces, and the validator accepts that prefix, so the two
  default-enabled hooks never reject each other's output.
- **Every provider call is optional in CI.** `AI_HOOKS_DRY_RUN=1` replaces each
  call with a fixed response, so the 68-case suite in `scripts/test.sh` runs on
  ubuntu and macOS with no API key. `AI_HOOKS_MOCK_RESPONSE` swaps in a
  provider reply, which is how the suite tests the review parser on findings.

## Requirements

| Requirement | Notes |
|-------------|-------|
| `git` 2.31+ | The hooks read the staged diff and the branch name. The installer uses `rev-parse --path-format=absolute` |
| `bash` | Every hook and script uses `#!/usr/bin/env bash`. CI runs the suite on ubuntu-latest and macos-latest |
| `curl` | Used for every provider API call |
| `jq` | Required. Hooks refuse to call a provider without it: `brew install jq` / `apt install jq` |

There is no npm package. Install with the one-line script, through the
pre-commit framework, or from a clone; all three run the same four scripts.

## Quick Start

### 1. Install

**One line.** From the root of your project:

```bash
curl -fsSL https://raw.githubusercontent.com/Sagargupta16/ai-git-hooks/main/scripts/get.sh | bash
```

[`get.sh`](scripts/get.sh) clones this repo to `~/.ai-git-hooks` (or updates
that clone if it exists) and runs the installer below for the current project.
It stops before cloning anything if you are not inside a git repository.
`AI_GIT_HOOKS_HOME` changes where the clone goes and `AI_GIT_HOOKS_REF` pins a
branch or tag. Running it again in another project reuses the clone.

**With the [pre-commit](https://pre-commit.com) framework.** Add the hooks to
`.pre-commit-config.yaml`:

```yaml
default_install_hook_types: [pre-commit, prepare-commit-msg, commit-msg, pre-push]
repos:
  - repo: https://github.com/Sagargupta16/ai-git-hooks
    rev: v1.2.0
    hooks:
      - id: ai-review            # pre-commit: AI code review
      - id: ai-commit-message    # prepare-commit-msg: generated message
      - id: commit-msg-validate  # commit-msg: conventional commit check
      - id: secret-scan          # pre-push: secret and large-file scan
```

Then run `pre-commit install`. Keep only the ids you want. The hooks read
`.ai-hooks.yml` from your project root as usual; copy
[`.ai-hooks.example.yml`](.ai-hooks.example.yml) there to configure them, or
they run on built-in defaults. Under pre-commit the pre-push scan takes its
range from `PRE_COMMIT_FROM_REF` / `PRE_COMMIT_TO_REF`, so it scans the same
commits as a directly installed hook.

**From a clone.** Clone it somewhere permanent. This directory is the source of
the hooks, not the project they run in.

```bash
git clone https://github.com/Sagargupta16/ai-git-hooks.git ~/tools/ai-git-hooks
cd /path/to/your-project
~/tools/ai-git-hooks/scripts/install.sh ~/tools/ai-git-hooks
```

The installer copies the four hooks into the hooks directory git reports for
your project (`git rev-parse --git-path hooks`, normally `.git/hooks/`) and
creates `.ai-hooks.yml` at the project root. Linked worktrees, submodules and a
`core.hooksPath` setting all resolve to the directory git actually runs. Run it
once per project you want the hooks in.

If the project uses husky, do not run the installer: it would replace husky's
own hook files (backed up as `<hook>.backup`), and the next `husky` run
regenerates them and drops the AI hooks. Call the hook scripts from your husky
hooks instead.

### 2. Configure

The installer seeds `.ai-hooks.yml` in your project root. The keys that matter:

```yaml
provider: claude            # claude | openai | ollama
model: claude-sonnet-5      # model to use

hooks:
  pre-commit:
    enabled: true
    severity: error         # error | warn | info
    max_files: 20
    ignore:
      - "*.lock"
      - "*.min.js"
      - "dist/**"

  prepare-commit-msg:
    enabled: true
    style: conventional     # conventional | simple | detailed
    ticket_prefix: true     # auto-detect ticket from branch name

  commit-msg:
    enabled: true
    convention: conventional
    max_length: 72

  pre-push:
    enabled: true
    scan_secrets: true
    scan_dependencies: true
    max_file_size: 5MB
```

### 3. Set your API key

```bash
# Claude (recommended)
export ANTHROPIC_API_KEY="sk-ant-..."

# OpenAI
export OPENAI_API_KEY="sk-..."

# Ollama (free, local - no key needed)
export OLLAMA_HOST="http://localhost:11434"
```

## Hook Details

### Pre-Commit: AI Code Review

Reviews staged changes and catches issues before they're committed.

**What it checks:**
- Bug patterns and logic errors
- Security vulnerabilities (XSS, SQL injection, etc.)
- Performance anti-patterns
- Missing error handling

**Example output** (the review lines depend on what the model returns):
```
[INFO] Reviewing 3 file(s)...
  src/api/users.js
  src/components/Dashboard.tsx
  src/utils/parse.js

[WARN] src/api/users.js:42
  SQL query uses string concatenation instead of a parameterized query.
  Fix: Use db.query('SELECT * FROM users WHERE id = $1', [id])

[INFO] src/components/Dashboard.tsx:108
  useEffect is missing 'userId' in its dependency array.

Summary: 0 error(s), 1 warning(s), 1 info
```

With `severity: warn` that warning blocks the commit; with the default
`severity: error` it is reported and the commit proceeds.

### Prepare-Commit-Msg: Auto-Generate Messages

Analyzes your diff and generates a commit message following your conventions.

```bash
git add .
git commit
# Hook auto-generates:
# feat(auth): add JWT refresh token rotation
#
# - Add refresh token endpoint with 7-day expiry
# - Implement token rotation on each refresh
# - Add rate limiting to prevent token abuse
```

### Commit-Msg: Validate Messages

Ensures commit messages follow your team's conventions.

```
[ERROR] Commit message validation failed.

Message: "fixed stuff"

Errors:
  - Subject does not match conventional commit format: type(scope): description

[INFO] Asking AI for a suggested fix...
Suggested message:
  fix: resolve null pointer in user authentication flow

[INFO] Fix your commit message and try again.
[INFO] Use 'git commit --no-verify' to bypass this check.
```

The checks are rule-based: conventional format, allowed type, subject length,
no trailing period, lowercase description, blank second line. The provider is
only asked for the suggested rewrite.

### Pre-Push: Security Scan

Scans the net diff of the commits about to be pushed. For a new branch that is
everything not already on a remote; for the first push of a repo it is every
file. A secret added in one commit and deleted in a later one in the same push
is not in the net diff, so it is not caught.

```
[INFO] Scanning for secrets...
[CRITICAL] Possible Anthropic API Key found in src/config.js:8
  const API_KEY = "***REDACTED***";
  Action: Remove the secret and rotate it immediately.

[INFO] Checking for large files...
[WARN] Large file detected: assets/video.mp4 (45 MB)
  Maximum allowed: 5 MB
  Action: Consider Git LFS or add to .gitignore.

--------------------------------------
Scan complete: 1 critical, 1 warning(s), 0 info

[ERROR] Push blocked due to 1 critical finding(s).
[INFO] Fix the issues above or use 'git push --no-verify' to bypass.
```

Each finding names the file and the line in that file. The size check reads
the blob in the pushed commit (`git cat-file -s`), so it sees what is being
pushed even when the file has since changed or been deleted locally.

Built-in patterns (40) cover AWS, GitHub (classic and fine-grained), Anthropic,
OpenAI (legacy and `sk-proj-` / `sk-svcacct-` / `sk-admin-`), Google, Slack,
Stripe, Twilio and SendGrid keys; PEM private keys of any type and PuTTY `.ppk`
keys; database connection strings and web, FTP and mail URLs with an inline
password; npm `_authToken` / `_auth`, Docker registry `auth`, `.netrc` logins
and Laravel `APP_KEY`; Unix crypt and bcrypt password hashes; and quoted
`password` / `secret` / `api_key` / `access_token` / `auth_token` /
`oauth_token` values assigned with `=` or `:` (so JSON and YAML configs count).
The matched value is redacted before it is printed. Unquoted `.env` lines such
as `DB_PASSWORD=admin123` are not matched.

**How well does it work?** Against the [leaky-repo](https://github.com/Plazmaz/leaky-repo)
corpus of fake credentials, the scan flags 34 of 175 credential lines in 21 of
44 files with 0 false positives, against 22 lines in 13 files for gitleaks
8.30.1 on its default rules. gitleaks still covers far more token formats (222
rules), so treat this hook as a zero-dependency push gate, not a replacement.
Methods, a noise check on four clean projects and the per-file table are in
[docs/benchmark.md](docs/benchmark.md); rerun it with `./scripts/benchmark.sh --gitleaks --noise`.

## What Runs On Every Commit

These hooks call your provider on ordinary git operations, so it is worth knowing
the request pattern before you install them.

| Hook | Provider requests | Notes |
|------|-------------------|-------|
| `pre-commit` | 1 per commit | Sends the staged diff, truncated to `max_diff_lines` (default 500). Skipped entirely when more than `max_files` (default 20) files are staged, or when every staged file matches `ignore`. |
| `prepare-commit-msg` | 1 per commit | A second request with the staged diff, truncated to 500 lines. Skipped for `git commit -m`, merges and squashes. |
| `commit-msg` | 0, or 1 on failure | Only asks for a suggestion when validation fails and `suggest_fix: true`. |
| `pre-push` | 0 | Regex secret scan, file-size check and `npm audit` / `pip-audit`. No AI involved. |

So a plain `git commit` with the shipped config makes two requests, and `git commit -m`
makes one. Requests are serial and block the operation until they return or `timeout`
(default 30 seconds) elapses. There is no caching, batching or retry.

Knobs that reduce the number of requests: set `enabled: false` on any hook you do
not want, lower `max_files` so more commits skip the review, or commit with `-m` to
skip the message generator.

`max_diff_lines` and `hooks.pre-commit.ignore` do not change the request count.
`max_diff_lines` truncates the payload, and `ignore` only decides whether the hook
runs at all: once it does run, the request carries `git diff --cached` for every
staged file, ignored ones included.

## Supported AI Providers

| Provider | Cost | Speed | Privacy | Setup |
|----------|------|-------|---------|-------|
| **Claude** (Anthropic) | API pricing | Fast | Cloud | API key |
| **OpenAI** | API pricing | Fast | Cloud | API key |
| **Ollama** (local) | Free | Varies | Full privacy | Local install |

### Using Ollama (Free & Private)

```bash
ollama pull llama3.1
```

Then edit the existing `provider` and `model` keys in `.ai-hooks.yml`:

```yaml
provider: ollama
model: llama3.1
```

Edit them in place - do not append duplicate keys to the end of the file. The
config reader takes the first match for a top-level key, so an appended
`provider:` is ignored and the original value keeps winning.

## Scripts

| Script | Description |
|--------|-------------|
| [`get.sh`](scripts/get.sh) | One-line install: clone or update `~/.ai-git-hooks`, then run `install.sh` here |
| [`install.sh`](scripts/install.sh) | Install hooks to your git project |
| [`uninstall.sh`](scripts/uninstall.sh) | Remove hooks from your project |
| [`test.sh`](scripts/test.sh) | Test hooks against sample diffs |
| [`demo.sh`](scripts/demo.sh) | Run the hooks in a throwaway repo, no API key needed |
| [`benchmark.sh`](scripts/benchmark.sh) | Score the secret scan (and optionally gitleaks) on the leaky-repo corpus |

## Troubleshooting

**Nothing happens when I commit.** The hooks live in the target project's
`.git/hooks/`, not in the ai-git-hooks clone. Check that
`ls -l /path/to/your-project/.git/hooks/pre-commit` exists and is executable. If you
ran `install.sh` from inside the ai-git-hooks clone, you installed the hooks into the
clone - `cd` to your project and run it again with the clone path as the argument.

**`./scripts/install.sh: Permission denied`.** The scripts ship with the executable
bit set, so a `git clone` gives you a runnable copy. If your copy lost the bit, run
`chmod +x scripts/*.sh hooks/*/*.sh`, or invoke it as `bash scripts/install.sh`.

**`'jq' is required but not installed`.** Install it: `brew install jq` or
`apt install jq`. Every provider call parses JSON with `jq`, so the pre-commit hook
blocks the commit without it.

**A secret scanner false positive is blocking my push.** Add the offending path to
`hooks.pre-push.ignore` in `.ai-hooks.yml` (glob syntax). That list ships empty, so
docs and test fixtures are scanned like everything else - they are common places for
a real key to leak. Keep any pattern you add as narrow as the false positive, because
listed files are not scanned at all. Binary, minified and lockfile types are skipped
by a built-in list already.

**Switching provider had no effect.** Edit the existing `provider:` and `model:` keys
in `.ai-hooks.yml`. Appending a second `provider:` line does nothing - the config
reader takes the first match. Run with `AI_HOOKS_DEBUG=1` to print the provider and
model actually in use.

**I need to commit right now.** `git commit --no-verify` and `git push --no-verify`
bypass the hooks for one operation. To turn a single hook off for good, set
`enabled: false` on it in `.ai-hooks.yml`. To remove everything, run
`/path/to/ai-git-hooks/scripts/uninstall.sh` from your project root - it restores any
hook it backed up during install.

## Contributing

Contributions welcome - new hooks, better prompts, new AI providers, or bug fixes.

1. Fork this repo
2. Create a feature branch
3. Add your changes with tests
4. Submit a PR

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

## More AI Developer Tools

| Project | Description |
|---------|-------------|
| [claude-cost-optimizer](https://github.com/Sagargupta16/claude-cost-optimizer) | Save 30-60% on Claude Code costs - proven strategies and benchmarks |
| [claude-code-recipes](https://github.com/Sagargupta16/claude-code-recipes) | 47 copy-paste recipes for Claude Code - commands, subagents, hooks, skills, MCP integration |
| [mcp-toolkit](https://github.com/Sagargupta16/mcp-toolkit) | TypeScript middleware toolkit for MCP servers - auth, caching, rate limiting (beta) |
| [agent-recipes](https://github.com/Sagargupta16/agent-recipes) | AI agent workflows for real-world dev tasks - code review, testing, security |

## License

[MIT](LICENSE)
