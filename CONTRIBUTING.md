# Contributing to AI Git Hooks

Thank you for your interest in contributing to AI Git Hooks! This guide will help you get started.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Writing Hooks](#writing-hooks)
- [Testing](#testing)
- [Submitting Changes](#submitting-changes)
- [Style Guide](#style-guide)

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## Getting Started

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/ai-git-hooks.git
   cd ai-git-hooks
   ```
3. Create a feature branch:
   ```bash
   git checkout -b feat/my-new-hook
   ```

## Development Setup

### Prerequisites

- **Bash** 4.0+ (macOS users: `brew install bash`)
- **Git** 2.20+
- **curl** (for API calls)
- **jq** (for JSON parsing): `brew install jq` / `apt install jq`
- **shellcheck** (CI gates on it): `brew install shellcheck` / `apt install shellcheck`

There is no Node.js or npm step. `package.json` is metadata only - it declares no
dependencies, and `scripts/test.sh` is pure bash.

### Optional

- An API key for Claude, OpenAI, or a running Ollama instance for end-to-end testing.

### Setup

```bash
cp .ai-hooks.example.yml .ai-hooks.yml
# Edit .ai-hooks.yml with your provider/key
```

## Project Structure

```
ai-git-hooks/
  hooks/
    pre-commit/
      ai-review.sh          # AI code review on staged changes
    prepare-commit-msg/
      auto-message.sh        # Auto-generate commit messages
    commit-msg/
      validate.sh            # Validate commit message format
    pre-push/
      security-scan.sh       # Scan for secrets and vulnerabilities
  scripts/
    install.sh               # Install hooks into a project
    uninstall.sh             # Remove hooks from a project
    test.sh                  # Run tests against sample diffs
  .ai-hooks.example.yml     # Example configuration
  package.json               # npm package metadata
```

## Writing Hooks

### Hook File Conventions

1. Place your hook in the appropriate `hooks/<hook-type>/` directory.
2. Use `#!/usr/bin/env bash` as the shebang line.
3. Set `set -euo pipefail` at the top for safety.
4. Source the shared utilities if available.
5. Use colored output via the helper functions (see existing hooks for examples).

### Required Sections in Every Hook

```bash
#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Hook Name - Brief description
# ============================================================================
# What it does, when it runs, what it checks.
# ============================================================================

# --- Color and formatting helpers ---
# --- Configuration loading ---
# --- Main logic ---
# --- Exit handling ---
```

### AI Provider Integration

When adding AI provider support:

- Support all three providers: Claude, OpenAI, and Ollama.
- Read the provider from `.ai-hooks.yml` config.
- Fall back to environment variable detection (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OLLAMA_HOST`).
- Handle network errors, timeouts, and rate limits gracefully.
- Never send sensitive data (API keys, secrets found in code) to the AI provider.

### Configuration

All hooks read from `.ai-hooks.yml`. When adding new options:

1. Add the option to `.ai-hooks.example.yml` with a comment explaining it.
2. Provide a sensible default in your hook if the option is missing.
3. Document the option in the README.

## Testing

### Running Tests

```bash
# Run all tests
./scripts/test.sh

# Run tests for a specific hook
./scripts/test.sh pre-commit
```

### Writing Tests

- Tests live in `scripts/test.sh` and use sample diffs/scenarios.
- Each hook should have at least:
  - A test with no staged files (should exit cleanly).
  - A test with a clean diff (should pass).
  - A test with a known-bad diff (should catch issues).
  - A test with missing API key (should show helpful error).

### Test Without AI

You can test hook logic without an AI provider by setting:

```bash
export AI_HOOKS_DRY_RUN=1
```

This will skip API calls and use mock responses.

## Submitting Changes

### Pull Request Process

1. Ensure your code follows the [Style Guide](#style-guide).
2. Update documentation if you changed behavior or added options.
3. Add or update tests for your changes.
4. Run the full test suite and confirm it passes.
5. Fill out the pull request template completely.

### Commit Messages

We follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`

**Scopes:** `pre-commit`, `prepare-commit-msg`, `commit-msg`, `pre-push`, `install`, `config`

**Examples:**
```
feat(pre-commit): add support for Python linting patterns
fix(install): handle spaces in directory paths
docs: update Ollama setup instructions
```

## Style Guide

### Shell Scripts

- Use `bash` (not `sh`) for all hooks and scripts.
- Quote all variable expansions: `"${var}"` not `$var`.
- Use `[[ ]]` for conditionals, not `[ ]`.
- Use `$(command)` for command substitution, not backticks.
- Indent with 2 spaces.
- Add comments for non-obvious logic.
- Use `local` for function variables.
- Name functions with `snake_case`.
- Name constants with `UPPER_SNAKE_CASE`.
- Always handle the case where a command might fail.

### YAML Configuration

- Use 2-space indentation.
- Add comments for every option.
- Group related options together.

## Reporting Issues

- Use the [bug report template](.github/ISSUE_TEMPLATE/bug-report.yml) for bugs.
- Use the [feature request template](.github/ISSUE_TEMPLATE/feature-request.yml) for ideas.
- Include your OS, bash version, git version, and AI provider when reporting bugs.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
