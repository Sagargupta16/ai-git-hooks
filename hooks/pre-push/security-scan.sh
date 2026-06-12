#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Pre-Push Security Scan
# ============================================================================
# Scans commits about to be pushed for:
#   - Hardcoded secrets (API keys, passwords, tokens)
#   - Large files that shouldn't be in the repo
#   - Dependency vulnerabilities (npm audit / pip audit)
#
# Arguments (passed by git):
#   stdin receives lines of: <local ref> <local sha> <remote ref> <remote sha>
#
# Exit codes:
#   0 - No critical issues found (push proceeds)
#   1 - Critical issues found (push blocked)
#
# Environment:
#   AI_HOOKS_DRY_RUN  - Set to "1" to skip actual scanning
#   AI_HOOKS_DEBUG     - Set to "1" for verbose output
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
  echo -e "${BOLD}${BLUE}  Pre-Push Security Scan${RESET}"
  echo -e "${BOLD}${BLUE}======================================${RESET}"
  echo ""
}

print_pass()     { echo -e "${GREEN}[PASS]${RESET} $1"; }
print_warn()     { echo -e "${YELLOW}[WARN]${RESET} $1"; }
print_error()    { echo -e "${RED}[ERROR]${RESET} $1"; }
print_critical() { echo -e "${RED}${BOLD}[CRITICAL]${RESET} $1"; }
print_info()     { echo -e "${CYAN}[INFO]${RESET} $1"; }
print_debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    echo -e "${DIM}[DEBUG] $1${RESET}"
  fi
}

# --- Configuration ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG_FILE="${REPO_ROOT}/.ai-hooks.yml"

SCAN_SECRETS="true"
SCAN_DEPS="true"
MAX_FILE_SIZE="5242880"  # 5MB in bytes
IGNORE_PATTERNS=()
DRY_RUN="${AI_HOOKS_DRY_RUN:-0}"

# Counters
CRITICAL_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0

yaml_get() {
  local key="$1"
  local file="${CONFIG_FILE}"

  [[ ! -f "${file}" ]] && return 1

  if [[ "${key}" == *.* ]]; then
    local parent="${key%%.*}"
    local child="${key#*.}"
    if [[ "${child}" == *.* ]]; then
      local mid="${child%%.*}"
      local leaf="${child#*.}"
      sed -n "/^${parent}:/,/^[^ ]/p" "${file}" \
        | sed -n "/^  ${mid}:/,/^  [^ ]/p" \
        | grep "^    ${leaf}:" \
        | head -1 \
        | sed 's/^[^:]*: *//' \
        | sed 's/^ *"//' | sed 's/" *$//' \
        | sed "s/^ *'//" | sed "s/' *$//"
    else
      sed -n "/^${parent}:/,/^[^ ]/p" "${file}" \
        | grep "^  ${child}:" \
        | head -1 \
        | sed 's/^[^:]*: *//' \
        | sed 's/^ *"//' | sed 's/" *$//' \
        | sed "s/^ *'//" | sed "s/' *$//"
    fi
  else
    grep "^${key}:" "${file}" \
      | head -1 \
      | sed 's/^[^:]*: *//' \
      | sed 's/^ *"//' | sed 's/" *$//' \
      | sed "s/^ *'//" | sed "s/' *$//"
  fi
}

# Convert size strings (5MB, 500KB, etc.) to bytes
parse_size() {
  local size_str="${1:-5MB}"
  local number unit

  number=$(echo "${size_str}" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  unit=$(echo "${size_str}" | grep -oE '[A-Za-z]+' | head -1 | tr '[:lower:]' '[:upper:]')

  [[ -z "${number}" ]] && { echo "5242880"; return; }

  case "${unit}" in
    B|BYTES)  echo "${number}" ;;
    KB)       echo "$((${number%.*} * 1024))" ;;
    MB)       echo "$((${number%.*} * 1024 * 1024))" ;;
    GB)       echo "$((${number%.*} * 1024 * 1024 * 1024))" ;;
    *)        echo "$((${number%.*} * 1024 * 1024))" ;;  # Default to MB
  esac
}

# Format bytes to human-readable
format_size() {
  local bytes="$1"
  if [[ "${bytes}" -ge 1073741824 ]]; then
    echo "$(( bytes / 1073741824 )) GB"
  elif [[ "${bytes}" -ge 1048576 ]]; then
    echo "$(( bytes / 1048576 )) MB"
  elif [[ "${bytes}" -ge 1024 ]]; then
    echo "$(( bytes / 1024 )) KB"
  else
    echo "${bytes} B"
  fi
}

load_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    print_debug "No .ai-hooks.yml found. Using defaults."
    return
  fi

  local val

  val=$(yaml_get "dry_run") && [[ "${val}" == "true" ]] && DRY_RUN="1"

  val=$(yaml_get "hooks.pre-push.enabled") && [[ "${val}" == "false" ]] && {
    print_debug "pre-push hook is disabled. Skipping."
    exit 0
  }
  val=$(yaml_get "hooks.pre-push.scan_secrets") && [[ -n "${val}" ]] && SCAN_SECRETS="${val}"
  val=$(yaml_get "hooks.pre-push.scan_dependencies") && [[ -n "${val}" ]] && SCAN_DEPS="${val}"

  val=$(yaml_get "hooks.pre-push.max_file_size") && [[ -n "${val}" ]] && MAX_FILE_SIZE=$(parse_size "${val}")
}

# --- Secret Patterns ---
# Built-in patterns for common secrets and credentials.

declare -a SECRET_PATTERNS=(
  # AWS
  'AKIA[0-9A-Z]{16}'
  'aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}'

  # GitHub
  'ghp_[A-Za-z0-9]{36}'
  'github_pat_[A-Za-z0-9]{22}_[A-Za-z0-9]{59}'
  'gho_[A-Za-z0-9]{36}'
  'ghu_[A-Za-z0-9]{36}'
  'ghs_[A-Za-z0-9]{36}'
  'ghr_[A-Za-z0-9]{36}'

  # Anthropic
  'sk-ant-api[a-zA-Z0-9_-]{20,}'

  # OpenAI
  'sk-[a-zA-Z0-9]{20,}'

  # Google
  'AIza[0-9A-Za-z_-]{35}'

  # Slack
  'xoxb-[0-9]{11}-[0-9]{11}-[a-zA-Z0-9]{24}'
  'xoxp-[0-9]{11}-[0-9]{11}-[a-zA-Z0-9]{24}'
  'xapp-[0-9]{1}-[A-Z0-9]{11}-[0-9]{13}-[a-z0-9]{64}'

  # Stripe
  'sk_live_[0-9a-zA-Z]{24,}'
  'rk_live_[0-9a-zA-Z]{24,}'

  # Twilio
  'SK[0-9a-fA-F]{32}'

  # SendGrid
  'SG\.[a-zA-Z0-9_-]{22}\.[a-zA-Z0-9_-]{43}'

  # Generic patterns
  'password\s*=\s*["\x27][^"\x27]{8,}["\x27]'
  'secret\s*=\s*["\x27][^"\x27]{8,}["\x27]'
  'api_key\s*=\s*["\x27][^"\x27]{8,}["\x27]'
  'apikey\s*=\s*["\x27][^"\x27]{8,}["\x27]'
  'access_token\s*=\s*["\x27][^"\x27]{8,}["\x27]'
  'auth_token\s*=\s*["\x27][^"\x27]{8,}["\x27]'
  'private_key\s*=\s*["\x27][^"\x27]{8,}["\x27]'

  # Private keys
  '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'

  # Connection strings
  'mongodb(\+srv)?://[a-zA-Z0-9._%-]+:[a-zA-Z0-9._%-]+@'
  'postgres(ql)?://[a-zA-Z0-9._%-]+:[a-zA-Z0-9._%-]+@'
  'mysql://[a-zA-Z0-9._%-]+:[a-zA-Z0-9._%-]+@'
  'redis://[a-zA-Z0-9._%-]*:[a-zA-Z0-9._%-]+@'
)

# Secret pattern friendly names (parallel array)
declare -a SECRET_NAMES=(
  "AWS Access Key ID"
  "AWS Secret Access Key"
  "GitHub Personal Access Token"
  "GitHub Fine-Grained PAT"
  "GitHub OAuth Token"
  "GitHub User Token"
  "GitHub Server Token"
  "GitHub Refresh Token"
  "Anthropic API Key"
  "OpenAI API Key"
  "Google API Key"
  "Slack Bot Token"
  "Slack User Token"
  "Slack App Token"
  "Stripe Secret Key"
  "Stripe Restricted Key"
  "Twilio API Key"
  "SendGrid API Key"
  "Hardcoded Password"
  "Hardcoded Secret"
  "Hardcoded API Key"
  "Hardcoded API Key"
  "Hardcoded Access Token"
  "Hardcoded Auth Token"
  "Hardcoded Private Key"
  "Private Key File"
  "MongoDB Connection String"
  "PostgreSQL Connection String"
  "MySQL Connection String"
  "Redis Connection String"
)

# Files to always skip when scanning for secrets
SECRET_SCAN_SKIP_FILES=(
  "*.lock"
  "*.min.js"
  "*.min.css"
  "*.map"
  "*.svg"
  "*.png"
  "*.jpg"
  "*.jpeg"
  "*.gif"
  "*.ico"
  "*.woff"
  "*.woff2"
  "*.ttf"
  "*.eot"
  "*.mp3"
  "*.mp4"
  "*.pdf"
  "*.zip"
  "*.tar.gz"
)

# --- Scanning Functions ---

# Reserved: per-file skip-list filtering is not yet wired into the diff-wide
# secret scan below, so ShellCheck sees this function as never invoked.
# shellcheck disable=SC2317,SC2329
should_skip_file() {
  local file="$1"

  for pattern in "${SECRET_SCAN_SKIP_FILES[@]}"; do
    # shellcheck disable=SC2254
    case "${file}" in
      ${pattern}) return 0 ;;
    esac
  done

  for pattern in "${IGNORE_PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "${file}" in
      ${pattern}) return 0 ;;
    esac
  done

  return 1
}

scan_secrets_in_range() {
  local range="$1"

  if [[ "${SCAN_SECRETS}" != "true" ]]; then
    print_debug "Secret scanning disabled."
    return
  fi

  print_info "Scanning for secrets..."

  # Get the diff for the commit range
  local diff_content
  diff_content=$(git diff "${range}" 2>/dev/null || true)

  if [[ -z "${diff_content}" ]]; then
    print_debug "No diff content to scan."
    return
  fi

  # Get list of added/modified files
  local files
  files=$(git diff --name-only "${range}" 2>/dev/null || true)

  local found_secrets=0

  for i in "${!SECRET_PATTERNS[@]}"; do
    local pattern="${SECRET_PATTERNS[$i]}"
    local name="${SECRET_NAMES[$i]}"

    # Search added lines (starting with +) in the diff
    local matches
    matches=$(echo "${diff_content}" | grep -nE "^\+.*${pattern}" 2>/dev/null || true)

    if [[ -n "${matches}" ]]; then
      while IFS= read -r match; do
        [[ -z "${match}" ]] && continue

        # Extract the line content, mask the secret
        local line_content
        line_content=$(echo "${match}" | sed 's/^[0-9]*://' | sed 's/^\+//')

        # Mask the matched secret value
        local masked
        masked=$(echo "${line_content}" | sed -E "s/${pattern}/***REDACTED***/g" | head -c 120)

        print_critical "Possible ${name} found"
        echo -e "  ${DIM}${masked}${RESET}"
        echo -e "  ${DIM}Action: Remove the secret and rotate it immediately.${RESET}"
        echo ""
        ((CRITICAL_COUNT++)) || true
        found_secrets=1
      done <<< "${matches}"
    fi
  done

  if [[ "${found_secrets}" -eq 0 ]]; then
    print_pass "No secrets detected."
  fi
}

scan_large_files() {
  local range="$1"

  print_info "Checking for large files..."

  local files
  files=$(git diff --name-only --diff-filter=ACMR "${range}" 2>/dev/null || true)

  if [[ -z "${files}" ]]; then
    print_debug "No files to check."
    return
  fi

  local found_large=0

  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    [[ ! -f "${file}" ]] && continue

    local file_size
    file_size=$(wc -c < "${file}" 2>/dev/null || echo "0")
    file_size=$(echo "${file_size}" | tr -d ' ')

    if [[ "${file_size}" -gt "${MAX_FILE_SIZE}" ]]; then
      local human_size
      human_size=$(format_size "${file_size}")
      local max_human
      max_human=$(format_size "${MAX_FILE_SIZE}")

      print_warn "Large file detected: ${file} (${human_size})"
      echo -e "  ${DIM}Maximum allowed: ${max_human}${RESET}"
      echo -e "  ${DIM}Action: Consider Git LFS or add to .gitignore.${RESET}"
      echo ""
      ((WARNING_COUNT++)) || true
      found_large=1
    fi
  done <<< "${files}"

  if [[ "${found_large}" -eq 0 ]]; then
    print_pass "No large files detected."
  fi
}

scan_dependencies() {
  if [[ "${SCAN_DEPS}" != "true" ]]; then
    print_debug "Dependency scanning disabled."
    return
  fi

  print_info "Checking dependency vulnerabilities..."

  local found_issues=0

  # npm audit
  if [[ -f "${REPO_ROOT}/package.json" ]] && command -v npm &>/dev/null; then
    print_debug "Running npm audit..."

    local npm_output
    npm_output=$(cd "${REPO_ROOT}" && npm audit --json 2>/dev/null) || true

    if [[ -n "${npm_output}" ]]; then
      local critical_count high_count
      critical_count=$(echo "${npm_output}" | jq -r '.metadata.vulnerabilities.critical // 0' 2>/dev/null || echo "0")
      high_count=$(echo "${npm_output}" | jq -r '.metadata.vulnerabilities.high // 0' 2>/dev/null || echo "0")

      if [[ "${critical_count}" -gt 0 ]]; then
        print_critical "npm audit: ${critical_count} critical vulnerabilities"
        echo -e "  ${DIM}Run 'npm audit' for details. Run 'npm audit fix' to resolve.${RESET}"
        echo ""
        ((CRITICAL_COUNT++)) || true
        found_issues=1
      fi

      if [[ "${high_count}" -gt 0 ]]; then
        print_warn "npm audit: ${high_count} high vulnerabilities"
        echo -e "  ${DIM}Run 'npm audit' for details.${RESET}"
        echo ""
        ((WARNING_COUNT++)) || true
        found_issues=1
      fi
    fi
  fi

  # pip audit (Python)
  if [[ -f "${REPO_ROOT}/requirements.txt" ]] || [[ -f "${REPO_ROOT}/pyproject.toml" ]]; then
    if command -v pip-audit &>/dev/null; then
      print_debug "Running pip-audit..."

      local pip_output
      pip_output=$(cd "${REPO_ROOT}" && pip-audit --format=json 2>/dev/null) || true

      if [[ -n "${pip_output}" ]]; then
        local vuln_count
        vuln_count=$(echo "${pip_output}" | jq -r 'length // 0' 2>/dev/null || echo "0")

        if [[ "${vuln_count}" -gt 0 ]]; then
          print_warn "pip-audit: ${vuln_count} vulnerabilities found"
          echo -e "  ${DIM}Run 'pip-audit' for details.${RESET}"
          echo ""
          ((WARNING_COUNT++)) || true
          found_issues=1
        fi
      fi
    else
      print_debug "pip-audit not installed. Skipping Python dependency scan."
    fi
  fi

  if [[ "${found_issues}" -eq 0 ]]; then
    print_pass "No dependency vulnerabilities found."
  fi
}

# --- Main ---

main() {
  print_header
  load_config

  if [[ "${DRY_RUN}" == "1" ]]; then
    print_info "Dry-run mode: Performing limited scan."
  fi

  # Read push information from stdin
  # Format: <local ref> <local sha> <remote ref> <remote sha>
  local local_ref local_sha remote_ref remote_sha
  local has_input=0

  while read -r local_ref local_sha remote_ref remote_sha; do
    has_input=1
    print_debug "Push: ${local_ref} (${local_sha:0:8}) -> ${remote_ref} (${remote_sha:0:8})"

    # Determine the range of commits to scan
    local range=""
    local zero_sha="0000000000000000000000000000000000000000"

    if [[ "${local_sha}" == "${zero_sha}" ]]; then
      # Deleting a branch, nothing to scan
      print_info "Branch deletion detected. Nothing to scan."
      continue
    fi

    if [[ "${remote_sha}" == "${zero_sha}" ]]; then
      # New branch - scan all commits not on any remote branch
      range="${local_sha}"
      # Get commits not reachable from any remote ref
      local commit_list
      commit_list=$(git log --oneline "${local_sha}" --not --remotes 2>/dev/null || true)
      if [[ -z "${commit_list}" ]]; then
        print_info "No new commits to scan."
        continue
      fi
      range="$(git merge-base HEAD "$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo 'HEAD~10')" 2>/dev/null || echo "${local_sha}~10")..${local_sha}"
    else
      range="${remote_sha}..${local_sha}"
    fi

    print_info "Scanning commits: ${range}"
    echo ""

    # Run scans
    scan_secrets_in_range "${range}"
    echo ""

    scan_large_files "${range}"
    echo ""

    if [[ "${DRY_RUN}" != "1" ]]; then
      scan_dependencies
      echo ""
    fi
  done

  # If no input from stdin (e.g., running manually), scan working tree
  if [[ "${has_input}" -eq 0 ]]; then
    print_info "No push data received. Scanning staged changes instead."
    echo ""

    local range="HEAD~1..HEAD"
    scan_secrets_in_range "${range}" 2>/dev/null || true
    echo ""
    scan_large_files "${range}" 2>/dev/null || true
    echo ""
  fi

  # Summary
  echo -e "${BOLD}--------------------------------------${RESET}"
  echo -e "${BOLD}Scan complete:${RESET} ${RED}${CRITICAL_COUNT} critical${RESET}, ${YELLOW}${WARNING_COUNT} warning(s)${RESET}, ${CYAN}${INFO_COUNT} info${RESET}"
  echo ""

  if [[ "${CRITICAL_COUNT}" -gt 0 ]]; then
    print_error "Push blocked due to ${CRITICAL_COUNT} critical finding(s)."
    print_info "Fix the issues above or use 'git push --no-verify' to bypass."
    exit 1
  fi

  if [[ "${WARNING_COUNT}" -gt 0 ]]; then
    print_warn "Push proceeding with ${WARNING_COUNT} warning(s). Review them before merging."
  else
    print_pass "All checks passed. Push proceeding."
  fi

  exit 0
}

main "$@"
