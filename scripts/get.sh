#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# AI Git Hooks - One-Line Installer
# ============================================================================
# From the root of the project you want the hooks in:
#
#   curl -fsSL https://raw.githubusercontent.com/Sagargupta16/ai-git-hooks/main/scripts/get.sh | bash
#
# What it does:
#   1. Checks that the current directory is inside a git repository
#   2. Clones ai-git-hooks to ~/.ai-git-hooks, or updates that clone if it is
#      already there
#   3. Runs scripts/install.sh from that clone for the current repository
#
# Environment:
#   AI_GIT_HOOKS_HOME  - Where the clone lives (default: ~/.ai-git-hooks)
#   AI_GIT_HOOKS_REPO  - Clone URL or path (default: the GitHub repo)
#   AI_GIT_HOOKS_REF   - Branch or tag to install (default: the repo's default branch)
#
# Everything runs inside main(), so a download cut off halfway executes nothing.
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RESET='\033[0m'

print_pass()  { echo -e "  ${GREEN}[OK]${RESET} $1"; }
print_error() { echo -e "  ${RED}[X]${RESET}  $1" >&2; }
print_info()  { echo -e "  ${CYAN}[*]${RESET}  $1"; }

main() {
  local home="${AI_GIT_HOOKS_HOME:-${HOME}/.ai-git-hooks}"
  local repo="${AI_GIT_HOOKS_REPO:-https://github.com/Sagargupta16/ai-git-hooks.git}"
  local ref="${AI_GIT_HOOKS_REF:-}"

  if ! command -v git &>/dev/null; then
    print_error "git is required but not installed."
    exit 1
  fi

  # Fail before cloning anything: install.sh targets the current repository
  if ! git rev-parse --show-toplevel &>/dev/null; then
    print_error "Not inside a git repository: $(pwd)"
    print_info "cd into the project you want the hooks in, then run this again."
    exit 1
  fi

  if [[ -d "${home}/.git" ]]; then
    print_info "Updating ${home}"
    git -C "${home}" fetch --quiet --depth 1 origin ${ref:+"${ref}"}
    git -C "${home}" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
  elif [[ -e "${home}" ]]; then
    print_error "${home} exists but is not a git clone of ai-git-hooks."
    print_info "Move it away, or set AI_GIT_HOOKS_HOME to another directory."
    exit 1
  else
    print_info "Cloning ${repo} into ${home}"
    git clone --quiet --depth 1 ${ref:+--branch "${ref}"} "${repo}" "${home}"
  fi
  print_pass "ai-git-hooks $(git -C "${home}" rev-parse --short HEAD) in ${home}"

  bash "${home}/scripts/install.sh" "${home}"
}

main "$@"
