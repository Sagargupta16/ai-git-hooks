#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# AI Git Hooks - Uninstall Script
# ============================================================================
# Removes AI-powered git hooks from your project's .git/hooks/ directory.
# Restores any backup hooks that were created during installation.
#
# Usage:
#   ./scripts/uninstall.sh [project-directory]
#
# If no directory is given, uses the current working directory.
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
  echo -e "${BOLD}${BLUE}  AI Git Hooks - Uninstaller${RESET}"
  echo -e "${BOLD}${BLUE}======================================${RESET}"
  echo ""
}

print_pass()  { echo -e "  ${GREEN}[OK]${RESET} $1"; }
print_warn()  { echo -e "  ${YELLOW}[!]${RESET}  $1"; }
print_error() { echo -e "  ${RED}[X]${RESET}  $1"; }
print_info()  { echo -e "  ${CYAN}[*]${RESET}  $1"; }

# --- Determine Paths ---

TARGET_DIR="${1:-$(pwd)}"
GIT_DIR="${TARGET_DIR}/.git"
HOOKS_DIR="${GIT_DIR}/hooks"

# Hook names and their identifying strings (parallel arrays for bash 3.2 compat)
HOOK_NAMES=("pre-commit" "prepare-commit-msg" "commit-msg" "pre-push")
HOOK_IDENTIFIERS=("AI Code Review" "Commit Message Generator" "Commit Message Validator" "Pre-Push Security Scan")

# --- Validation ---

if [[ ! -d "${GIT_DIR}" ]]; then
  print_error "Not a git repository: ${TARGET_DIR}"
  print_info "Run this script from your project root."
  exit 1
fi

if [[ ! -d "${HOOKS_DIR}" ]]; then
  print_info "No hooks directory found. Nothing to uninstall."
  exit 0
fi

# --- Uninstall ---

main() {
  print_header

  print_info "Removing AI hooks from: ${HOOKS_DIR}"
  echo ""

  local removed=0
  local skipped=0

  for i in "${!HOOK_NAMES[@]}"; do
    local hook_name="${HOOK_NAMES[$i]}"
    local hook_file="${HOOKS_DIR}/${hook_name}"
    local identifier="${HOOK_IDENTIFIERS[$i]}"
    local backup_file="${HOOKS_DIR}/${hook_name}.backup"

    if [[ ! -f "${hook_file}" ]]; then
      print_info "${hook_name}: Not installed. Skipping."
      continue
    fi

    # Verify this is our hook before removing
    if grep -q "${identifier}" "${hook_file}" 2>/dev/null; then
      rm -f "${hook_file}"
      ((removed++)) || true

      # Restore backup if it exists
      if [[ -f "${backup_file}" ]]; then
        mv "${backup_file}" "${hook_file}"
        chmod +x "${hook_file}"
        print_pass "${hook_name}: Removed. Original hook restored from backup."
      else
        print_pass "${hook_name}: Removed."
      fi
    else
      print_warn "${hook_name}: Hook exists but doesn't appear to be an AI hook. Skipping."
      ((skipped++)) || true
    fi
  done

  echo ""

  # Optionally remove config
  local config_file="${TARGET_DIR}/.ai-hooks.yml"
  if [[ -f "${config_file}" ]]; then
    echo -e -n "  Remove .ai-hooks.yml config file? [y/N] "
    read -r answer 2>/dev/null || answer="n"
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
      rm -f "${config_file}"
      print_pass "Removed .ai-hooks.yml"
    else
      print_info "Kept .ai-hooks.yml"
    fi
  fi

  echo ""
  echo -e "${BOLD}${GREEN}======================================${RESET}"
  echo -e "${BOLD}${GREEN}  Uninstall Complete${RESET}"
  echo -e "${BOLD}${GREEN}======================================${RESET}"
  echo ""
  echo -e "  Removed ${removed} hook(s). Skipped ${skipped}."
  echo ""

  if [[ "${removed}" -gt 0 ]]; then
    print_info "AI hooks have been removed. Your git workflow is back to normal."
  fi

  if [[ "${skipped}" -gt 0 ]]; then
    print_warn "Some hooks were skipped because they weren't AI hooks."
    print_info "Remove them manually from: ${HOOKS_DIR}"
  fi

  echo ""
}

main
