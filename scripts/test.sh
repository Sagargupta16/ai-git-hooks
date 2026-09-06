#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# AI Git Hooks - Test Suite
# ============================================================================
# Tests hook scripts with sample diffs and scenarios.
# Runs in dry-run mode by default to avoid API calls.
#
# Usage:
#   ./scripts/test.sh              # Run all tests
#   ./scripts/test.sh pre-commit   # Run tests for a specific hook
#
# Environment:
#   AI_HOOKS_DRY_RUN is automatically set to "1" during testing.
# ============================================================================

# --- Color and Formatting ---
RED='\033[0;31m'
# shellcheck disable=SC2034  # part of the shared color palette
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Force dry-run mode during tests
export AI_HOOKS_DRY_RUN="1"

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=""
FILTER="${1:-all}"

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# --- Utility Functions ---

print_header() {
  echo ""
  echo -e "${BOLD}${BLUE}======================================${RESET}"
  echo -e "${BOLD}${BLUE}  AI Git Hooks - Test Suite${RESET}"
  echo -e "${BOLD}${BLUE}======================================${RESET}"
  echo ""
}

print_test_group() {
  echo ""
  echo -e "${BOLD}${CYAN}--- $1 ---${RESET}"
  echo ""
}

pass() {
  local name="$1"
  echo -e "  ${GREEN}PASS${RESET} ${name}"
  ((TESTS_RUN++)) || true
  ((TESTS_PASSED++)) || true
}

fail() {
  local name="$1"
  local reason="${2:-}"
  echo -e "  ${RED}FAIL${RESET} ${name}"
  if [[ -n "${reason}" ]]; then
    echo -e "       ${DIM}${reason}${RESET}"
  fi
  ((TESTS_RUN++)) || true
  ((TESTS_FAILED++)) || true
}

# --- Test Helpers ---

# Usage: setup_test_repo [no-config]
# Pass "no-config" to leave .ai-hooks.yml out, which exercises each hook's
# built-in defaults path instead of the example config.
setup_test_repo() {
  local config_mode="${1:-with-config}"

  TEST_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'ai-hooks-test')
  cd "${TEST_DIR}"
  git init --quiet
  git config user.email "test@example.com"
  git config user.name "Test User"

  # Copy example config
  if [[ "${config_mode}" != "no-config" ]] && [[ -f "${REPO_ROOT}/.ai-hooks.example.yml" ]]; then
    cp "${REPO_ROOT}/.ai-hooks.example.yml" ".ai-hooks.yml"
  fi

  # Create initial commit so HEAD exists
  echo "initial" > README.md
  git add README.md
  git commit --quiet -m "initial commit"
}

cleanup_test_repo() {
  if [[ -n "${TEST_DIR}" ]] && [[ -d "${TEST_DIR}" ]]; then
    cd "${REPO_ROOT}"
    rm -rf "${TEST_DIR}"
  fi
}

# Create a staged file for testing
stage_file() {
  local filename="$1"
  local content="${2:-test content}"
  echo "${content}" > "${filename}"
  git add "${filename}"
}

# Commit a file, then echo the stdin line git would hand the pre-push hook:
#   <local ref> <local sha> <remote ref> <remote sha>
# The remote sha is the commit before this one, so the hook scans exactly the
# new commit.
commit_and_ref_line() {
  local filename="$1"
  local content="$2"

  local base ref
  base=$(git rev-parse HEAD)
  ref="refs/heads/$(git rev-parse --abbrev-ref HEAD)"

  printf '%s\n' "${content}" > "${filename}"
  git add "${filename}"
  git commit --quiet -m "test: add ${filename}"

  echo "${ref} $(git rev-parse HEAD) ${ref} ${base}"
}

# Usage: set_pre_push_ignore <glob> [<glob> ...]
# Replaces the empty `ignore: []` default under hooks.pre-push with the given
# globs. The ignore-list tests supply their own patterns through this helper so
# they assert the mechanism rather than whatever .ai-hooks.example.yml happens
# to ship. Tightening or widening the shipped default cannot break them.
set_pre_push_ignore() {
  local list=""
  local pattern
  for pattern in "$@"; do
    list="${list}      - \"${pattern}\"
"
  done

  local rewritten
  rewritten=$(awk -v list="${list}" '
    $0 == "    ignore: []" { printf "    ignore:\n%s", list; next }
    { print }
  ' .ai-hooks.yml)
  printf '%s\n' "${rewritten}" > .ai-hooks.yml
}

# Usage: set_hook_max_length <hook-block> <value>
# Rewrites max_length inside one hook block of the test repo's config.
# `max_length` appears under two blocks, so the rewrite has to be scoped.
set_hook_max_length() {
  local block="  $1:"
  local value="$2"

  local rewritten
  rewritten=$(awk -v block="${block}" -v value="${value}" '
    $0 == block { in_block = 1; print; next }
    /^  [a-z-]+:$/ { in_block = 0 }
    in_block && $0 ~ /^    max_length:/ { print "    max_length: " value; next }
    { print }
  ' .ai-hooks.yml)
  printf '%s\n' "${rewritten}" > .ai-hooks.yml
}

# A syntactically valid but well-known-fake AWS access key ID. Built by
# concatenation so this test file does not itself contain a full match, which
# would make the repo's own pre-push hook flag it.
fake_aws_key() {
  echo "AKIA""IOSFODNN7EXAMPLE"
}

# --- Pre-Commit Tests ---

test_pre_commit() {
  print_test_group "Pre-Commit: AI Code Review"

  local hook="${REPO_ROOT}/hooks/pre-commit/ai-review.sh"

  # Test: Script exists and is valid bash
  if [[ -f "${hook}" ]]; then
    if bash -n "${hook}" 2>/dev/null; then
      pass "Script syntax is valid"
    else
      fail "Script has syntax errors"
    fi
  else
    fail "Script not found: ${hook}"
    return
  fi

  # Test: No staged files should exit cleanly
  setup_test_repo
  local output
  if output=$(bash "${hook}" 2>&1); then
    if echo "${output}" | grep -qi "no staged files\|skipping"; then
      pass "No staged files: exits cleanly with info message"
    else
      pass "No staged files: exits with code 0"
    fi
  else
    fail "No staged files: should exit 0 but got non-zero"
  fi
  cleanup_test_repo

  # Test: With staged files in dry-run mode
  setup_test_repo
  stage_file "test.js" "const x = 1;"
  if output=$(bash "${hook}" 2>&1); then
    if echo "${output}" | grep -qi "dry.run\|no issues\|pass"; then
      pass "Dry-run mode: reviews staged files without API call"
    else
      pass "Dry-run mode: exits successfully"
    fi
  else
    fail "Dry-run mode: should not block commit" "$(echo "${output}" | tail -3)"
  fi
  cleanup_test_repo

  # Test: a staged file matching hooks.pre-commit.ignore is skipped, not reviewed
  setup_test_repo
  stage_file "package-lock.json" '{"lockfileVersion": 3}'
  if output=$(bash "${hook}" 2>&1); then
    if echo "${output}" | grep -qi "match ignore patterns"; then
      pass "Ignored files: package-lock.json skipped via config ignore list"
    else
      fail "Ignored files: exited 0 but did not report skipping the ignored file" "$(echo "${output}" | tail -3)"
    fi
  else
    fail "Ignored files: should exit 0" "$(echo "${output}" | tail -3)"
  fi
  cleanup_test_repo

  # Test: runs against built-in defaults when no .ai-hooks.yml exists
  setup_test_repo no-config
  stage_file "defaults.js" "const y = 2;"
  if output=$(bash "${hook}" 2>&1); then
    if echo "${output}" | grep -qi "no .ai-hooks.yml found"; then
      pass "No config: falls back to built-in defaults"
    else
      fail "No config: exited 0 but did not report using defaults" "$(echo "${output}" | tail -3)"
    fi
  else
    fail "No config: should not block the commit" "$(echo "${output}" | tail -3)"
  fi
  cleanup_test_repo

  # Test: Script handles missing jq gracefully (we can't easily test this
  # without removing jq, so we just verify the check exists in the script)
  if grep -q "command -v jq" "${hook}"; then
    pass "Dependency check: jq availability check present"
  else
    fail "Dependency check: missing jq check in script"
  fi
}

# --- Prepare-Commit-Msg Tests ---

test_prepare_commit_msg() {
  print_test_group "Prepare-Commit-Msg: Auto Message"

  local hook="${REPO_ROOT}/hooks/prepare-commit-msg/auto-message.sh"

  # Test: Script syntax
  if [[ -f "${hook}" ]]; then
    if bash -n "${hook}" 2>/dev/null; then
      pass "Script syntax is valid"
    else
      fail "Script has syntax errors"
    fi
  else
    fail "Script not found: ${hook}"
    return
  fi

  # Test: Skips when commit source is "message" (git commit -m)
  setup_test_repo
  local msg_file
  msg_file=$(mktemp)
  echo "" > "${msg_file}"
  if output=$(bash "${hook}" "${msg_file}" "message" 2>&1); then
    pass "Skips when user provides -m message"
  else
    fail "Should skip for -m commits"
  fi
  rm -f "${msg_file}"
  cleanup_test_repo

  # Test: Generates message in dry-run mode
  setup_test_repo
  stage_file "feature.js" "function hello() { return 'world'; }"
  msg_file=$(mktemp)
  echo "" > "${msg_file}"
  if output=$(bash "${hook}" "${msg_file}" "" 2>&1); then
    local generated
    generated=$(head -1 "${msg_file}")
    if [[ -n "${generated}" ]]; then
      pass "Dry-run: generates mock message: '${generated}'"
    else
      pass "Dry-run: runs without error"
    fi
  else
    fail "Dry-run: should not fail" "$(echo "${output}" | tail -3)"
  fi
  rm -f "${msg_file}"
  cleanup_test_repo

  # Test: Skips merge commits
  setup_test_repo
  msg_file=$(mktemp)
  echo "Merge branch 'feature'" > "${msg_file}"
  if output=$(bash "${hook}" "${msg_file}" "merge" 2>&1); then
    pass "Skips merge commits"
  else
    fail "Should skip merge commits"
  fi
  rm -f "${msg_file}"
  cleanup_test_repo

  # Test: Ticket detection patterns exist
  if grep -q "JIRA\|Linear\|grep -oE" "${hook}"; then
    pass "Ticket detection: branch name parsing present"
  else
    fail "Ticket detection: missing branch name parsing"
  fi

  # Test: the ticket prefix is spent out of the max_length budget, and when the
  # finished subject still will not pass commit-msg the generator says so.
  # Both hooks read their own max_length, so squeeze both to a value the mock
  # message cannot meet once "PROJ-42: " is prepended.
  setup_test_repo
  set_hook_max_length "prepare-commit-msg" 20
  set_hook_max_length "commit-msg" 20
  git checkout --quiet -b "feature/PROJ-42-add-login"
  stage_file "login.js" "function login() { return true; }"
  msg_file=$(mktemp)
  echo "" > "${msg_file}"
  if output=$(bash "${hook}" "${msg_file}" "" 2>&1); then
    if ! echo "${output}" | grep -q "commit-msg will reject it"; then
      fail "Length budget: prefixed subject is over max_length but no warning was printed" "$(echo "${output}" | tail -3)"
    elif bash "${REPO_ROOT}/hooks/commit-msg/validate.sh" "${msg_file}" >/dev/null 2>&1; then
      fail "Length budget: warned about a rejection the validator does not actually make"
    else
      pass "Length budget: generator warns, and commit-msg does reject the prefixed subject"
    fi
  else
    fail "Length budget: generator should still write a message" "$(echo "${output}" | tail -3)"
  fi
  rm -f "${msg_file}"
  cleanup_test_repo
}

# --- Commit-Msg Tests ---

test_commit_msg() {
  print_test_group "Commit-Msg: Validate"

  local hook="${REPO_ROOT}/hooks/commit-msg/validate.sh"

  # Test: Script syntax
  if [[ -f "${hook}" ]]; then
    if bash -n "${hook}" 2>/dev/null; then
      pass "Script syntax is valid"
    else
      fail "Script has syntax errors"
    fi
  else
    fail "Script not found: ${hook}"
    return
  fi

  # Test: Valid conventional commit message
  setup_test_repo
  local msg_file
  msg_file=$(mktemp)
  echo "feat(auth): add login functionality" > "${msg_file}"
  if output=$(bash "${hook}" "${msg_file}" 2>&1); then
    pass "Valid message: 'feat(auth): add login functionality' accepted"
  else
    fail "Valid message should pass validation" "$(echo "${output}" | tail -3)"
  fi
  rm -f "${msg_file}"
  cleanup_test_repo

  # Test: Valid message without scope
  setup_test_repo
  msg_file=$(mktemp)
  echo "fix: resolve null pointer exception" > "${msg_file}"
  if output=$(bash "${hook}" "${msg_file}" 2>&1); then
    pass "Valid message: 'fix: resolve null pointer exception' accepted"
  else
    fail "Valid scopeless message should pass"
  fi
  rm -f "${msg_file}"
  cleanup_test_repo

  # Test: Invalid message (no type prefix)
  setup_test_repo
  msg_file=$(mktemp)
  echo "fixed stuff" > "${msg_file}"
  if output=$(bash "${hook}" "${msg_file}" 2>&1); then
    fail "Invalid message 'fixed stuff' should be rejected"
  else
    if echo "${output}" | grep -qi "error\|fail\|invalid\|does not match"; then
      pass "Invalid message: 'fixed stuff' correctly rejected"
    else
      pass "Invalid message: rejected with exit code 1"
    fi
  fi
  rm -f "${msg_file}"
  cleanup_test_repo

  # Test: Empty commit message
  setup_test_repo
  msg_file=$(mktemp)
  echo "" > "${msg_file}"
  if output=$(bash "${hook}" "${msg_file}" 2>&1); then
    fail "Empty message should be rejected"
  else
    pass "Empty message: correctly rejected"
  fi
  rm -f "${msg_file}"
  cleanup_test_repo

  # Test: the ticket prefix must not let a message skip the description rules.
  # The prefix carries its own colon, so a naive "cut at the first colon" reads
  # the type as the description and the lowercase rule stops firing.
  setup_test_repo
  msg_file=$(mktemp)
  echo "PROJ-42: feat: Add login" > "${msg_file}"
  if output=$(bash "${hook}" "${msg_file}" 2>&1); then
    fail "Ticket prefix: uppercase description should be rejected, prefix or not" "$(echo "${output}" | tail -3)"
  else
    if echo "${output}" | grep -qi "start with lowercase"; then
      pass "Ticket prefix: 'PROJ-42: feat: Add login' still flagged for uppercase"
    else
      fail "Ticket prefix: rejected but not for the uppercase description" "$(echo "${output}" | tail -3)"
    fi
  fi
  rm -f "${msg_file}"
  cleanup_test_repo

  # Test: Message too long (config max_length is 72)
  setup_test_repo
  msg_file=$(mktemp)
  echo "feat: this is a very long commit message that exceeds the maximum allowed length of seventy-two characters and should be flagged" > "${msg_file}"
  if output=$(bash "${hook}" "${msg_file}" 2>&1); then
    fail "Long message: 128-char subject should be rejected" "$(echo "${output}" | tail -3)"
  else
    if echo "${output}" | grep -qi "characters (max"; then
      pass "Long message: correctly flagged for exceeding max_length"
    else
      fail "Long message: rejected but not for length" "$(echo "${output}" | tail -3)"
    fi
  fi
  rm -f "${msg_file}"
  cleanup_test_repo

  # Test: Breaking change indicator
  setup_test_repo
  msg_file=$(mktemp)
  echo "feat!: breaking change in API" > "${msg_file}"
  if output=$(bash "${hook}" "${msg_file}" 2>&1); then
    pass "Breaking change: 'feat!: ...' accepted"
  else
    fail "Breaking change format should be valid" "$(echo "${output}" | tail -3)"
  fi
  rm -f "${msg_file}"
  cleanup_test_repo

  # Test: round trip. Both message hooks are enabled by default, so whatever
  # prepare-commit-msg writes must pass commit-msg. With ticket_prefix on and a
  # Jira/Linear branch name, the generated subject carries a "PROJ-42: " prefix
  # -- if the validator rejects that, committing is impossible without
  # --no-verify.
  setup_test_repo
  local generator="${REPO_ROOT}/hooks/prepare-commit-msg/auto-message.sh"
  git checkout --quiet -b "feature/PROJ-42-add-login"
  stage_file "login.js" "function login() { return true; }"
  msg_file=$(mktemp)
  echo "" > "${msg_file}"
  if bash "${generator}" "${msg_file}" "" >/dev/null 2>&1; then
    local round_trip_msg
    round_trip_msg=$(head -1 "${msg_file}")
    if [[ "${round_trip_msg}" != PROJ-42:* ]]; then
      fail "Round trip: generator did not add the ticket prefix" "got: ${round_trip_msg}"
    elif output=$(bash "${hook}" "${msg_file}" 2>&1); then
      pass "Round trip: validator accepts generated '${round_trip_msg}'"
    else
      fail "Round trip: validator rejected the generated message" "got: ${round_trip_msg}"
    fi
  else
    fail "Round trip: generator failed to write a message"
  fi
  rm -f "${msg_file}"
  cleanup_test_repo
}

# --- Pre-Push Tests ---

test_pre_push() {
  print_test_group "Pre-Push: Security Scan"

  local hook="${REPO_ROOT}/hooks/pre-push/security-scan.sh"

  # Test: Script syntax
  if [[ -f "${hook}" ]]; then
    if bash -n "${hook}" 2>/dev/null; then
      pass "Script syntax is valid"
    else
      fail "Script has syntax errors"
    fi
  else
    fail "Script not found: ${hook}"
    return
  fi

  # Test: Script contains secret patterns
  local pattern_count
  pattern_count=$(grep -c 'SECRET_PATTERNS' "${hook}" || echo "0")
  if [[ "${pattern_count}" -gt 0 ]]; then
    pass "Secret detection: patterns defined in script"
  else
    fail "Secret detection: no patterns found"
  fi

  # Test: Script checks for AWS keys
  if grep -q 'AKIA' "${hook}"; then
    pass "Secret detection: AWS key pattern present"
  else
    fail "Secret detection: missing AWS key pattern"
  fi

  # Test: Script checks for private keys
  if grep -q 'PRIVATE KEY' "${hook}"; then
    pass "Secret detection: private key pattern present"
  else
    fail "Secret detection: missing private key pattern"
  fi

  # Test: Large file detection exists
  if grep -q 'max_file_size\|MAX_FILE_SIZE\|large file\|Large file' "${hook}"; then
    pass "Large file detection: implemented"
  else
    fail "Large file detection: not found"
  fi

  # Test: npm audit integration exists
  if grep -q 'npm audit' "${hook}"; then
    pass "Dependency scanning: npm audit integration present"
  else
    fail "Dependency scanning: npm audit not found"
  fi

  # Test: a committed secret is detected and blocks the push.
  # This is the headline behavior of the hook, so assert it end to end rather
  # than grepping the script for pattern literals.
  setup_test_repo
  local ref_line
  ref_line=$(commit_and_ref_line "config.js" "const AWS_ACCESS_KEY_ID = '$(fake_aws_key)';")
  if output=$(echo "${ref_line}" | bash "${hook}" 2>&1); then
    fail "Secret scan: a staged AWS key should block the push" "$(echo "${output}" | tail -3)"
  else
    if echo "${output}" | grep -q "CRITICAL"; then
      pass "Secret scan: AWS key in config.js reported CRITICAL and blocked the push"
    else
      fail "Secret scan: exited non-zero but reported no CRITICAL finding" "$(echo "${output}" | tail -3)"
    fi
  fi
  cleanup_test_repo

  # Test: the shipped ignore list is empty, so a secret in a doc still blocks.
  # Wiring hooks.pre-push.ignore up must not quietly shrink what gets scanned.
  setup_test_repo
  ref_line=$(commit_and_ref_line "docs.md" "Example: AWS_ACCESS_KEY_ID = $(fake_aws_key)")
  if output=$(echo "${ref_line}" | bash "${hook}" 2>&1); then
    fail "Default ignore list: a secret in docs.md must still block the push" "$(echo "${output}" | tail -3)"
  else
    if echo "${output}" | grep -q "CRITICAL"; then
      pass "Default ignore list: empty by default, so docs.md is still scanned"
    else
      fail "Default ignore list: exited non-zero but reported no CRITICAL finding" "$(echo "${output}" | tail -3)"
    fi
  fi
  cleanup_test_repo

  # Test: a secret in a file matching an opted-in hooks.pre-push.ignore pattern
  # does NOT block. This is the only escape hatch from a false positive in docs
  # or fixtures, so it has to actually work. The pattern comes from the test,
  # not from .ai-hooks.example.yml, so changing the shipped default cannot
  # break this assertion.
  setup_test_repo
  set_pre_push_ignore "docs/**"
  mkdir -p docs
  ref_line=$(commit_and_ref_line "docs/setup.md" "Example: AWS_ACCESS_KEY_ID = $(fake_aws_key)")
  if output=$(echo "${ref_line}" | bash "${hook}" 2>&1); then
    if echo "${output}" | grep -q "CRITICAL"; then
      fail "Ignore list: 'docs/**' was configured but still reported CRITICAL" "$(echo "${output}" | tail -3)"
    else
      pass "Ignore list: secret in docs/setup.md suppressed by configured pattern"
    fi
  else
    fail "Ignore list: 'docs/**' is ignored, so the push should not be blocked" "$(echo "${output}" | tail -3)"
  fi
  cleanup_test_repo

  # Test: falls back to scanning the working tree when git sends no ref lines.
  # Uses </dev/null, not `echo ""` -- a single blank line still enters the read
  # loop, so it never reaches this code path.
  setup_test_repo
  if output=$(bash "${hook}" < /dev/null 2>&1); then
    if echo "${output}" | grep -qi "no push data received"; then
      pass "No push data: falls back to scanning local changes and exits 0"
    else
      fail "No push data: exited 0 but did not take the fallback path" "$(echo "${output}" | tail -3)"
    fi
  else
    fail "No push data: should exit 0 on a clean repo" "$(echo "${output}" | tail -3)"
  fi
  cleanup_test_repo
}

# --- Install/Uninstall Tests ---

test_install() {
  print_test_group "Installation Scripts"

  local install_script="${REPO_ROOT}/scripts/install.sh"
  local uninstall_script="${REPO_ROOT}/scripts/uninstall.sh"

  # Test: Install script syntax
  if bash -n "${install_script}" 2>/dev/null; then
    pass "install.sh: syntax is valid"
  else
    fail "install.sh: syntax errors"
  fi

  # Test: Uninstall script syntax
  if bash -n "${uninstall_script}" 2>/dev/null; then
    pass "uninstall.sh: syntax is valid"
  else
    fail "uninstall.sh: syntax errors"
  fi

  # Test: Install to a test repo
  setup_test_repo
  if output=$(bash "${install_script}" "${REPO_ROOT}" 2>&1); then
    # Verify hooks were installed
    local hooks_installed=0
    local hook_name
    for hook_name in pre-commit prepare-commit-msg commit-msg pre-push; do
      if [[ -f "${TEST_DIR}/.git/hooks/${hook_name}" ]]; then
        hooks_installed=$((hooks_installed + 1))
      fi
    done

    if [[ "${hooks_installed}" -eq 4 ]]; then
      pass "install.sh: all 4 hooks installed"
    else
      fail "install.sh: only ${hooks_installed}/4 hooks installed"
    fi

    # Verify hooks are executable
    if [[ -x "${TEST_DIR}/.git/hooks/pre-commit" ]]; then
      pass "install.sh: hooks are executable"
    else
      fail "install.sh: hooks not marked executable"
    fi

    # Verify config was created
    if [[ -f "${TEST_DIR}/.ai-hooks.yml" ]]; then
      pass "install.sh: .ai-hooks.yml created"
    else
      fail "install.sh: .ai-hooks.yml not created"
    fi
  else
    fail "install.sh: exited with error" "$(echo "${output}" | tail -3)"
  fi

  # Test: Uninstall from the test repo
  if output=$(echo "n" | bash "${uninstall_script}" "${TEST_DIR}" 2>&1); then
    local hooks_remaining=0
    local hook_name
    for hook_name in pre-commit prepare-commit-msg commit-msg pre-push; do
      if [[ -f "${TEST_DIR}/.git/hooks/${hook_name}" ]]; then
        hooks_remaining=$((hooks_remaining + 1))
      fi
    done

    if [[ "${hooks_remaining}" -eq 0 ]]; then
      pass "uninstall.sh: all hooks removed"
    else
      fail "uninstall.sh: ${hooks_remaining} hooks still present"
    fi
  else
    fail "uninstall.sh: exited with error" "$(echo "${output}" | tail -3)"
  fi

  cleanup_test_repo
}

# --- Config File Tests ---

test_config() {
  print_test_group "Configuration"

  # Test: Example config exists
  if [[ -f "${REPO_ROOT}/.ai-hooks.example.yml" ]]; then
    pass "Example config file exists"
  else
    fail "Example config file missing"
    return
  fi

  # Test: Example config has all expected sections
  local config="${REPO_ROOT}/.ai-hooks.example.yml"

  if grep -q "^provider:" "${config}"; then
    pass "Config: 'provider' key present"
  else
    fail "Config: missing 'provider' key"
  fi

  if grep -q "pre-commit:" "${config}"; then
    pass "Config: pre-commit section present"
  else
    fail "Config: missing pre-commit section"
  fi

  if grep -q "prepare-commit-msg:" "${config}"; then
    pass "Config: prepare-commit-msg section present"
  else
    fail "Config: missing prepare-commit-msg section"
  fi

  if grep -q "commit-msg:" "${config}"; then
    pass "Config: commit-msg section present"
  else
    fail "Config: missing commit-msg section"
  fi

  if grep -q "pre-push:" "${config}"; then
    pass "Config: pre-push section present"
  else
    fail "Config: missing pre-push section"
  fi
}

# --- Summary ---

print_summary() {
  echo ""
  echo -e "${BOLD}${BLUE}======================================${RESET}"
  echo -e "${BOLD}${BLUE}  Test Results${RESET}"
  echo -e "${BOLD}${BLUE}======================================${RESET}"
  echo ""
  echo -e "  Total:  ${TESTS_RUN}"
  echo -e "  Passed: ${GREEN}${TESTS_PASSED}${RESET}"
  echo -e "  Failed: ${RED}${TESTS_FAILED}${RESET}"
  echo ""

  if [[ "${TESTS_FAILED}" -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All tests passed!${RESET}"
  else
    echo -e "  ${RED}${BOLD}${TESTS_FAILED} test(s) failed.${RESET}"
  fi
  echo ""
}

# --- Main ---

main() {
  print_header

  echo -e "${DIM}Running in dry-run mode (AI_HOOKS_DRY_RUN=1)${RESET}"
  echo -e "${DIM}Test filter: ${FILTER}${RESET}"

  case "${FILTER}" in
    pre-commit)
      test_pre_commit
      ;;
    prepare-commit-msg)
      test_prepare_commit_msg
      ;;
    commit-msg)
      test_commit_msg
      ;;
    pre-push)
      test_pre_push
      ;;
    install)
      test_install
      ;;
    config)
      test_config
      ;;
    all)
      test_config
      test_pre_commit
      test_prepare_commit_msg
      test_commit_msg
      test_pre_push
      test_install
      ;;
    *)
      echo -e "${RED}Unknown test filter: ${FILTER}${RESET}"
      echo "Usage: $0 [all|pre-commit|prepare-commit-msg|commit-msg|pre-push|install|config]"
      exit 1
      ;;
  esac

  print_summary

  # Exit with failure if any tests failed
  if [[ "${TESTS_FAILED}" -gt 0 ]]; then
    exit 1
  fi
}

# Ensure cleanup on exit
trap cleanup_test_repo EXIT

main
