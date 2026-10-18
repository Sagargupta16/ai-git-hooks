#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# AI Git Hooks - Demo
# ============================================================================
# Walks through the hooks in a throwaway repository, with no API key needed:
#   1. install the four hooks
#   2. a vague commit message is rejected by the validator
#   3. a plain `git commit` gets a generated conventional message
#   4. a push carrying an AWS key is blocked by the secret scan
#
# Runs in dry-run mode (AI_HOOKS_DRY_RUN=1), so the review and the message
# generator use their fixed stand-in replies instead of calling a provider.
# The validator and the secret scan make no AI call, so their output is
# exactly what a real run prints. Everything happens in a temp directory that
# is deleted on exit.
#
# Usage:
#   ./scripts/demo.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR=""

BOLD='\033[1m'
GREEN='\033[0;32m'
RESET='\033[0m'

cleanup() {
  if [[ -n "${WORK_DIR}" ]] && [[ -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

# Print a command as if typed at a prompt, then run it. Hook failures are the
# point of the demo, so a non-zero exit is reported rather than fatal.
run() {
  local shown="" arg
  for arg in "$@"; do
    [[ "${arg}" == *" "* ]] && arg="\"${arg}\""
    shown="${shown:+${shown} }${arg}"
  done
  echo ""
  echo -e "${BOLD}${GREEN}\$${RESET} ${BOLD}${shown}${RESET}"
  local rc=0
  "$@" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo -e "${BOLD}(exit ${rc})${RESET}"
  fi
}

main() {
  export AI_HOOKS_DRY_RUN=1
  export GIT_EDITOR=true
  # Keep the user's global hooks and config out of the throwaway repo
  export GIT_CONFIG_GLOBAL=/dev/null

  WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'ai-hooks-demo')
  trap cleanup EXIT

  git init --quiet --bare "${WORK_DIR}/remote.git"
  git init --quiet "${WORK_DIR}/app"
  cd "${WORK_DIR}/app"
  git config user.email "demo@example.com"
  git config user.name "Demo"
  git config core.autocrlf false
  git remote add origin "${WORK_DIR}/remote.git"

  echo -e "${BOLD}1. Install the hooks${RESET}"
  "${SOURCE_DIR}/scripts/install.sh" "${SOURCE_DIR}" | grep -E 'Installed|Created'

  echo ""
  echo -e "${BOLD}2. A vague message is rejected${RESET}"
  printf 'export function login(user) {\n  return user.active;\n}\n' > login.js
  run git add login.js .ai-hooks.yml
  run git commit -m "fixed stuff"

  echo ""
  echo -e "${BOLD}3. A plain commit gets a generated message${RESET}"
  run git commit
  run git log --oneline -1

  echo ""
  echo -e "${BOLD}4. A push with a key in it is blocked${RESET}"
  printf 'export const config = {\n  region: "us-east-1",\n  accessKeyId: "%s",\n};\n' "AKIA""IOSFODNN7EXAMPLE" > config.js
  run git add config.js
  run git commit -m "feat: add aws config"
  run git push origin HEAD
}

main "$@"
