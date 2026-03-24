# AI Git Hooks

> AI-powered git hooks that review your code, generate commit messages, catch bugs, and scan for security issues — before you push.

Drop-in git hooks that use AI (Claude, OpenAI, Ollama) to automate code quality checks at every stage of your git workflow.

## Hooks

| Hook | Description | Trigger |
|------|-------------|---------|
| [AI Code Review](hooks/pre-commit/) | Reviews staged changes for bugs, style issues, and anti-patterns | `pre-commit` |
| [Commit Message Generator](hooks/prepare-commit-msg/) | Auto-generates conventional commit messages from your diff | `prepare-commit-msg` |
| [Commit Message Validator](hooks/commit-msg/) | Validates commit messages follow conventions | `commit-msg` |
| [Pre-Push Security Scan](hooks/pre-push/) | Scans for secrets, vulnerabilities, and large files | `pre-push` |

## Quick Start

### 1. Install

```bash
git clone https://github.com/Sagargupta16/ai-git-hooks.git
cd ai-git-hooks
./scripts/install.sh
```

### 2. Configure

Create `.ai-hooks.yml` in your project root:

```yaml
provider: claude            # claude | openai | ollama
model: claude-sonnet-4-6    # model to use

hooks:
  pre-commit:
    enabled: true
    severity: warn          # error | warn | info
    max-files: 20
    ignore:
      - "*.lock"
      - "*.min.js"
      - "dist/**"

  prepare-commit-msg:
    enabled: true
    style: conventional     # conventional | simple | detailed
    prefix: true            # auto-detect ticket from branch name

  commit-msg:
    enabled: true
    convention: conventional
    max-length: 72

  pre-push:
    enabled: true
    scan-secrets: true
    scan-dependencies: true
    max-file-size: 5MB
```

### 3. Set your API key

```bash
# Claude (recommended)
export ANTHROPIC_API_KEY="sk-ant-..."

# OpenAI
export OPENAI_API_KEY="sk-..."

# Ollama (free, local — no key needed)
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

**Example output:**
```
AI Code Review (3 files changed)

src/api/users.js:42
  WARNING: SQL query uses string concatenation instead of parameterized query.
  Fix: Use db.query('SELECT * FROM users WHERE id = $1', [id])

src/components/Dashboard.tsx:108
  INFO: useEffect missing dependency 'userId' in dependency array.

src/utils/parse.js
  OK: No issues found.

Summary: 1 warning, 1 info, 0 errors
```

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
Commit Message Validation
Message: "fixed stuff"

ERRORS:
  - Type prefix missing. Expected: feat|fix|docs|style|refactor|test|chore
  - Message too vague. Describe what was fixed and why.

Suggested: "fix: resolve null pointer in user authentication flow"
```

### Pre-Push: Security Scan

Scans all commits about to be pushed for security issues.

```
Pre-Push Security Scan

CRITICAL: Possible API key found in src/config.js:8
  Line: const API_KEY = "sk-ant-api03-..."
  Action: Remove the key and rotate it immediately.

WARNING: Large file detected: assets/video.mp4 (45 MB)
  Action: Consider Git LFS or .gitignore.

Scan complete: 1 critical, 1 warning
Push blocked due to critical finding.
```

## Supported AI Providers

| Provider | Cost | Speed | Privacy | Setup |
|----------|------|-------|---------|-------|
| **Claude** (Anthropic) | API pricing | Fast | Cloud | API key |
| **OpenAI** (GPT-4) | API pricing | Fast | Cloud | API key |
| **Ollama** (local) | Free | Varies | Full privacy | Local install |

### Using Ollama (Free & Private)

```bash
ollama pull llama3.1
echo 'provider: ollama' >> .ai-hooks.yml
echo 'model: llama3.1' >> .ai-hooks.yml
```

## Scripts

| Script | Description |
|--------|-------------|
| [`install.sh`](scripts/install.sh) | Install hooks to your git project |
| [`uninstall.sh`](scripts/uninstall.sh) | Remove hooks from your project |
| [`test.sh`](scripts/test.sh) | Test hooks against sample diffs |

## Contributing

Contributions welcome — new hooks, better prompts, new AI providers, or bug fixes.

1. Fork this repo
2. Create a feature branch
3. Add your changes with tests
4. Submit a PR

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

## License

[MIT](LICENSE)
