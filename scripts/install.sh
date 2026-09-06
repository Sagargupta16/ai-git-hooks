#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# AI Git Hooks - Installation Script
# ============================================================================
# Installs AI-powered git hooks into your project's .git/hooks/ directory.
#
# Usage:
#   ./scripts/install.sh [path-to-ai-git-hooks]
#
# Hooks are installed into the .git/hooks/ of the CURRENT directory, so run this
# from the project you want the hooks in:
#   cd /path/to/your-project
#   /path/to/ai-git-hooks/scripts/install.sh /path/to/ai-git-hooks
#
# Running it as ./scripts/install.sh from inside the ai-git-hooks clone is
# valid, but it installs the hooks into the clone, not into your project.
#
# What it does:
#   1. Copies hook scripts to .git/hooks/
#   2. Makes them executable
#   3. Creates .ai-hooks.yml from example if it doesn't exist
#   4. Detects available AI providers from environment
# ============================================================================

# --- Color and Formatting ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

print_header() {
  echo ""
  echo -e "${BOLD}${BLUE}======================================${RESET}"
  echo -e "${BOLD}${BLUE}  AI Git Hooks - Installer${RESET}"
  echo -e "${BOLD}${BLUE}======================================${RESET}"
  echo ""
}

print_pass()  { echo -e "  ${GREEN}[OK]${RESET} $1"; }
print_warn()  { echo -e "  ${YELLOW}[!]${RESET}  $1"; }
print_error() { echo -e "  ${RED}[X]${RESET}  $1"; }
print_info()  { echo -e "  ${CYAN}[*]${RESET}  $1"; }
print_step()  { echo -e "\n${BOLD}$1${RESET}"; }

# --- Determine Paths ---

# Source directory: where the ai-git-hooks repo lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${1:-}" ]]; then
  SOURCE_DIR="$(cd "$1" && pwd)"
else
  SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Target directory: the project where we're installing hooks
TARGET_DIR="$(pwd)"
GIT_DIR="${TARGET_DIR}/.git"
HOOKS_DIR="${GIT_DIR}/hooks"

# --- Validation ---

validate_source() {
  print_step "1. Validating source..."

  if [[ ! -d "${SOURCE_DIR}/hooks" ]]; then
    print_error "Cannot find hooks directory at: ${SOURCE_DIR}/hooks"
    print_info "Make sure you're passing the correct path to the ai-git-hooks repo."
    exit 1
  fi

  local hooks_found=0
  local hook_file
  for hook_file in \
    "pre-commit/ai-review.sh" \
    "prepare-commit-msg/auto-message.sh" \
    "commit-msg/validate.sh" \
    "pre-push/security-scan.sh"; do
    if [[ -f "${SOURCE_DIR}/hooks/${hook_file}" ]]; then
      hooks_found=$((hooks_found + 1))
    fi
  done

  print_pass "Found ${hooks_found} hook(s) in ${SOURCE_DIR}/hooks/"
}

validate_target() {
  print_step "2. Validating target project..."

  if [[ ! -d "${GIT_DIR}" ]]; then
    print_error "Not a git repository: ${TARGET_DIR}"
    print_info "Run this script from your project root (where .git/ is)."
    print_info "Or initialize git first: git init"
    exit 1
  fi

  print_pass "Git repository found: ${TARGET_DIR}"

  # Create hooks directory if it doesn't exist
  if [[ ! -d "${HOOKS_DIR}" ]]; then
    mkdir -p "${HOOKS_DIR}"
    print_info "Created hooks directory: ${HOOKS_DIR}"
  fi
}

# --- Installation ---

install_hooks() {
  print_step "3. Installing hooks..."

  local installed=0

  # Pre-commit hook
  if [[ -f "${SOURCE_DIR}/hooks/pre-commit/ai-review.sh" ]]; then
    # If there's an existing hook, back it up
    if [[ -f "${HOOKS_DIR}/pre-commit" ]]; then
      # Check if it's our hook
      if grep -q "AI Code Review" "${HOOKS_DIR}/pre-commit" 2>/dev/null; then
        print_info "Updating existing AI pre-commit hook."
      else
        cp "${HOOKS_DIR}/pre-commit" "${HOOKS_DIR}/pre-commit.backup"
        print_warn "Backed up existing pre-commit hook to pre-commit.backup"
      fi
    fi
    cp "${SOURCE_DIR}/hooks/pre-commit/ai-review.sh" "${HOOKS_DIR}/pre-commit"
    chmod +x "${HOOKS_DIR}/pre-commit"
    print_pass "Installed: pre-commit (AI Code Review)"
    ((installed++)) || true
  fi

  # Prepare-commit-msg hook
  if [[ -f "${SOURCE_DIR}/hooks/prepare-commit-msg/auto-message.sh" ]]; then
    if [[ -f "${HOOKS_DIR}/prepare-commit-msg" ]]; then
      if grep -q "Commit Message Generator" "${HOOKS_DIR}/prepare-commit-msg" 2>/dev/null; then
        print_info "Updating existing AI prepare-commit-msg hook."
      else
        cp "${HOOKS_DIR}/prepare-commit-msg" "${HOOKS_DIR}/prepare-commit-msg.backup"
        print_warn "Backed up existing prepare-commit-msg hook to prepare-commit-msg.backup"
      fi
    fi
    cp "${SOURCE_DIR}/hooks/prepare-commit-msg/auto-message.sh" "${HOOKS_DIR}/prepare-commit-msg"
    chmod +x "${HOOKS_DIR}/prepare-commit-msg"
    print_pass "Installed: prepare-commit-msg (Auto Message)"
    ((installed++)) || true
  fi

  # Commit-msg hook
  if [[ -f "${SOURCE_DIR}/hooks/commit-msg/validate.sh" ]]; then
    if [[ -f "${HOOKS_DIR}/commit-msg" ]]; then
      if grep -q "Commit Message Validator" "${HOOKS_DIR}/commit-msg" 2>/dev/null; then
        print_info "Updating existing AI commit-msg hook."
      else
        cp "${HOOKS_DIR}/commit-msg" "${HOOKS_DIR}/commit-msg.backup"
        print_warn "Backed up existing commit-msg hook to commit-msg.backup"
      fi
    fi
    cp "${SOURCE_DIR}/hooks/commit-msg/validate.sh" "${HOOKS_DIR}/commit-msg"
    chmod +x "${HOOKS_DIR}/commit-msg"
    print_pass "Installed: commit-msg (Validator)"
    ((installed++)) || true
  fi

  # Pre-push hook
  if [[ -f "${SOURCE_DIR}/hooks/pre-push/security-scan.sh" ]]; then
    if [[ -f "${HOOKS_DIR}/pre-push" ]]; then
      if grep -q "Pre-Push Security Scan" "${HOOKS_DIR}/pre-push" 2>/dev/null; then
        print_info "Updating existing AI pre-push hook."
      else
        cp "${HOOKS_DIR}/pre-push" "${HOOKS_DIR}/pre-push.backup"
        print_warn "Backed up existing pre-push hook to pre-push.backup"
      fi
    fi
    cp "${SOURCE_DIR}/hooks/pre-push/security-scan.sh" "${HOOKS_DIR}/pre-push"
    chmod +x "${HOOKS_DIR}/pre-push"
    print_pass "Installed: pre-push (Security Scan)"
    ((installed++)) || true
  fi

  echo ""
  print_info "Installed ${installed} hook(s) to ${HOOKS_DIR}/"
}

# --- Configuration ---

setup_config() {
  print_step "4. Setting up configuration..."

  local config_file="${TARGET_DIR}/.ai-hooks.yml"
  local example_file="${SOURCE_DIR}/.ai-hooks.example.yml"

  if [[ -f "${config_file}" ]]; then
    print_info "Config file already exists: .ai-hooks.yml (not overwritten)"
  elif [[ -f "${example_file}" ]]; then
    cp "${example_file}" "${config_file}"
    print_pass "Created .ai-hooks.yml from example config."
    print_info "Edit .ai-hooks.yml to customize your settings."
  else
    print_warn "No example config found. You'll need to create .ai-hooks.yml manually."
  fi
}

# --- Provider Detection ---

detect_providers() {
  print_step "5. Detecting AI providers..."

  local found_provider=""

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    print_pass "Claude (Anthropic): API key detected"
    found_provider="claude"
  else
    print_info "Claude: ANTHROPIC_API_KEY not set"
  fi

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    print_pass "OpenAI: API key detected"
    [[ -z "${found_provider}" ]] && found_provider="openai"
  else
    print_info "OpenAI: OPENAI_API_KEY not set"
  fi

  # Check if Ollama is running
  local ollama_host="${OLLAMA_HOST:-http://localhost:11434}"
  if curl -s --max-time 2 "${ollama_host}/api/tags" &>/dev/null; then
    print_pass "Ollama: Server running at ${ollama_host}"
    [[ -z "${found_provider}" ]] && found_provider="ollama"
  else
    print_info "Ollama: Not running (${ollama_host})"
  fi

  if [[ -z "${found_provider}" ]]; then
    echo ""
    print_warn "No AI provider detected. Set one of:"
    echo -e "    ${DIM}export ANTHROPIC_API_KEY=\"sk-ant-...\"  # Claude${RESET}"
    echo -e "    ${DIM}export OPENAI_API_KEY=\"sk-...\"         # OpenAI${RESET}"
    echo -e "    ${DIM}ollama serve                            # Ollama (free)${RESET}"
  else
    # Update config to use detected provider
    local config_file="${TARGET_DIR}/.ai-hooks.yml"
    if [[ -f "${config_file}" ]]; then
      # Only update if it's still set to the default
      local current_provider
      current_provider=$(grep "^provider:" "${config_file}" | head -1 | sed 's/^provider: *//' || true)
      if [[ "${current_provider}" != "${found_provider}" ]] && [[ -n "${current_provider}" ]]; then
        print_info "Config provider is '${current_provider}'. Detected '${found_provider}'."
        print_info "Update .ai-hooks.yml if you want to switch providers."
      fi
    fi
  fi
}

# --- Dependencies Check ---

check_dependencies() {
  print_step "6. Checking dependencies..."

  # Required
  if command -v curl &>/dev/null; then
    print_pass "curl: $(curl --version | head -1 | cut -d' ' -f1,2)"
  else
    print_error "curl is required but not installed."
  fi

  if command -v git &>/dev/null; then
    print_pass "git: $(git --version)"
  else
    print_error "git is required but not installed."
  fi

  # Recommended
  if command -v jq &>/dev/null; then
    print_pass "jq: $(jq --version 2>/dev/null || echo 'installed')"
  else
    print_warn "jq is recommended but not installed."
    print_info "Install: brew install jq (macOS) or apt install jq (Linux)"
  fi

  # Optional
  if command -v shellcheck &>/dev/null; then
    print_pass "shellcheck: $(shellcheck --version 2>/dev/null | head -2 | tail -1 || echo 'installed') (optional)"
  fi
}

# --- Summary ---

print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}======================================${RESET}"
  echo -e "${BOLD}${GREEN}  Installation Complete!${RESET}"
  echo -e "${BOLD}${GREEN}======================================${RESET}"
  echo ""
  echo -e "  Your AI git hooks are now active. They will run automatically"
  echo -e "  when you commit or push."
  echo ""
  echo -e "  ${BOLD}Next steps:${RESET}"
  echo -e "    1. Edit ${CYAN}.ai-hooks.yml${RESET} to configure your preferences"
  echo -e "    2. Set your AI provider API key (if not already done)"
  echo -e "    3. Try a commit: ${DIM}git add . && git commit${RESET}"
  echo ""
  echo -e "  ${BOLD}Useful commands:${RESET}"
  echo -e "    Bypass a hook:  ${DIM}git commit --no-verify${RESET}"
  echo -e "    Dry-run mode:   ${DIM}export AI_HOOKS_DRY_RUN=1${RESET}"
  echo -e "    Uninstall:      ${DIM}${SOURCE_DIR}/scripts/uninstall.sh${RESET}"
  echo ""
}

# --- Main ---

main() {
  print_header
  validate_source
  validate_target
  install_hooks
  setup_config
  detect_providers
  check_dependencies
  print_summary
}

main "$@"
