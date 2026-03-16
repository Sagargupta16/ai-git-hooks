## Description

<!-- Briefly describe what this PR does. -->

## Type of Change

- [ ] New hook
- [ ] Bug fix
- [ ] Enhancement to existing hook
- [ ] New AI provider support
- [ ] Documentation update
- [ ] CI / tooling change
- [ ] Other (describe below)

## Hook(s) Affected

- [ ] `pre-commit` (AI Code Review)
- [ ] `prepare-commit-msg` (Auto Message)
- [ ] `commit-msg` (Validate)
- [ ] `pre-push` (Security Scan)
- [ ] `scripts/install.sh`
- [ ] `scripts/uninstall.sh`
- [ ] Configuration (`.ai-hooks.yml`)
- [ ] None / not applicable

## Testing

<!-- Describe how you tested your changes. -->

- [ ] Ran `./scripts/test.sh` and all tests pass
- [ ] Tested manually with a real git repository
- [ ] Tested with dry-run mode (`AI_HOOKS_DRY_RUN=1`)
- [ ] Tested with Claude provider
- [ ] Tested with OpenAI provider
- [ ] Tested with Ollama provider

## AI Provider Compatibility

- [ ] Works with Claude
- [ ] Works with OpenAI
- [ ] Works with Ollama
- [ ] Not applicable (no AI calls)

## Checklist

- [ ] My code follows the project's [style guide](CONTRIBUTING.md#style-guide)
- [ ] I have updated documentation for any changed behavior
- [ ] I have added/updated the example config (`.ai-hooks.example.yml`) if I added new options
- [ ] I have added tests for my changes
- [ ] My commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)

## Screenshots / Terminal Output

<!-- If applicable, paste terminal output or screenshots showing the hook in action. -->

## Additional Notes

<!-- Anything else reviewers should know. -->
