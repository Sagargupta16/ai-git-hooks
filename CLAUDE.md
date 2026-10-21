# CLAUDE.md

> This file stacks on top of the workspace root at `C:\Code\GitHub\`:
> - Root [`CLAUDE.md`](../../CLAUDE.md) -- voice, rules, routing map, references, skills, slash commands, conventions.
> - Root [`MEMORY.md`](../../MEMORY.md) -- live facts across repos.
> - Root [`STATUS.md`](../../STATUS.md) -- live PR/CI/security dashboard.
> - [`.claude/resources/`](../../.claude/resources/README.md) -- deep reference for collaboration, workflow, git, OSS, debugging, voice.
>
> Read those first. The guidance below only adds **repo-specific context** -- it does not override anything in the root.

## Project

Drop-in AI-powered git hooks (code review, commit message generation/validation, pre-push security scan) backed by Claude, OpenAI, or Ollama. Public community tool at github.com/Sagargupta16/ai-git-hooks, MIT.

## Stack

- **Language**: Bash (pure shell, `jq` for JSON)
- **Framework**: none -- standalone hook scripts
- **Database**: none
- **Package manager**: none at runtime; `package.json` is npm metadata only (no dependencies)
- **Deploy target**: none -- users clone and run `scripts/install.sh`

## Run

```
./scripts/install.sh      # install hooks into a target repo's .git/hooks/
./scripts/uninstall.sh    # remove them
```

## Test

```
./scripts/test.sh                # all hooks, dry-run (AI_HOOKS_DRY_RUN=1, no API calls)
./scripts/test.sh pre-commit     # single hook
shellcheck -x hooks/**/*.sh scripts/*.sh   # lint (CI-gated)
```

## Entry points

- `hooks/pre-commit/ai-review.sh` -- AI review of staged changes
- `hooks/prepare-commit-msg/auto-message.sh` -- generates conventional commit message from diff
- `hooks/commit-msg/validate.sh` -- validates commit message format
- `hooks/pre-push/security-scan.sh` -- secrets / large-file / dependency scan
- `scripts/install.sh` -- copies hooks into target repo, seeds `.ai-hooks.yml`

## Key files

- `.ai-hooks.example.yml` -- the config contract users copy to `.ai-hooks.yml`; any new hook option must land here with comments
- `.github/workflows/test.yml` -- CI: shellcheck, dry-run tests on ubuntu + macos, install/uninstall round-trip

## Gotchas

- `AI_HOOKS_DRY_RUN=1` skips all provider API calls -- tests rely on it; keep the flag honored in every hook.
- Scripts must pass `shellcheck -x` and stay executable with LF line endings (Windows dev machine; CI runs Linux/macOS only).
- Provider auth is env-var only (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) -- never write keys into config files or examples. The Ollama host is not auth: it reads from `ollama.host` in config, with `OLLAMA_HOST` taking precedence.
- Adding a hook or script means updating two places: `scripts/test.sh` and the README hooks table. CI discovers `hooks/**/*.sh` and `scripts/*.sh` by file scan for both the shellcheck lint and the executable-bit assertion.
- `hooks.pre-push.ignore` ships empty on purpose. Anything listed there is dropped from the secret scan, so a default entry would silently shrink coverage for every user.
- `SECRET_PATTERNS` and `SECRET_NAMES` in `security-scan.sh` are parallel arrays; keep them the same length. Rerun `./scripts/benchmark.sh --gitleaks --noise` after any pattern change and update `docs/benchmark.md` and the README numbers from its output.
- Under the pre-commit framework the hooks get no git stdin or `$2`: pre-push reads `PRE_COMMIT_FROM_REF`/`PRE_COMMIT_TO_REF` (or `PRE_COMMIT_LOCAL_BRANCH` on a first push), prepare-commit-msg reads `PRE_COMMIT_COMMIT_MSG_SOURCE`.
- The README demo SVGs come from `docs/demo/demo.json` (lines copied from `./scripts/demo.sh` output) rendered with svg-forge's `forge.py --kind typing --timing long --width 880 --theme both`.
- The How It Works flowchart comes from `docs/diagrams/hook-flow.yaml`, rendered with orrery (the command is in the spec's header). Its notes quote the pattern count and the 5 MB default, so re-render it when a hook's outcome, provider call or those numbers change; `orrery verify` checks its `evidence:` lines still match the hooks.

## Install              (CLI / tool)

- Clone somewhere permanent, then from the target project root: `/path/to/ai-git-hooks/scripts/install.sh /path/to/ai-git-hooks`
- `install.sh` resolves the target from the current directory (`git rev-parse --show-toplevel`, hooks dir from `--git-path hooks`), so running it from inside the ai-git-hooks clone installs the hooks into the clone and leaves the user's project untouched
- One-line install: `curl -fsSL https://raw.githubusercontent.com/Sagargupta16/ai-git-hooks/main/scripts/get.sh | bash` clones to `~/.ai-git-hooks` and runs `install.sh`. pre-commit framework users consume `.pre-commit-hooks.yaml` instead (needs a git tag for `rev:`)
- `scripts/test.sh` covers the pre-push first-push and new-branch paths (remote sha all zeros); that gap is how the first-push scan bug shipped in 1.0.0

## Usage                (CLI / tool)

- Hooks fire automatically on `git commit` / `git push` once installed
- `./scripts/test.sh [hook-name]` -- exercise hooks against sample diffs without API calls

## Config               (CLI / tool)

- Config file: `.ai-hooks.yml` in the *target* project root (seeded from `.ai-hooks.example.yml`)
- Format: YAML -- provider/model at top level, per-hook blocks under `hooks:`
