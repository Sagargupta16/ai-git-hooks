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
#   Under the pre-commit framework the range comes from PRE_COMMIT_FROM_REF and
#   PRE_COMMIT_TO_REF instead (or PRE_COMMIT_LOCAL_BRANCH for a first push).
#
# Exit codes:
#   0 - No critical issues found (push proceeds)
#   1 - Critical issues found (push blocked)
#
# Environment:
#   AI_HOOKS_DRY_RUN  - Set to "1" to skip the dependency audit only. Secret
#                       and large-file scanning still run, and a secret finding
#                       still blocks the push. This hook makes no AI API calls,
#                       so there is nothing else for dry-run to stub out.
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
  if [[ "${AI_HOOKS_DEBUG:-0}" == "1" ]]; then
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

# Read list values (lines starting with "- ") from a key inside the pre-push
# block. Both ends of the outer range matter: '^  pre-push:' anchors the start
# so a longer key cannot match first, and '^  [a-z]' ends it at the NEXT hook
# block. Ending at '^[^ ]' instead only stopped at a top-level key, so the
# range ran past '  pre-commit:' and this function returned that block's
# ignore list -- a pre-commit ignore silently disabled the secret scan.
yaml_get_list() {
  local section_key="$1"
  local file="${CONFIG_FILE}"

  [[ ! -f "${file}" ]] && return 1

  local block
  block=$(sed -n '/^  pre-push:/,/^  [a-z]/p' "${file}" | sed -n "/^    ${section_key}:/,/^    [a-z]/p")
  echo "${block}" | grep '^ *- ' | sed 's/^ *- *//' | sed 's/"//g' | sed "s/'//g"
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
  # 'debug: true' in config enables the same verbose output as AI_HOOKS_DEBUG=1
  val=$(yaml_get "debug") && [[ "${val}" == "true" ]] && export AI_HOOKS_DEBUG=1

  val=$(yaml_get "hooks.pre-push.enabled") && [[ "${val}" == "false" ]] && {
    print_debug "pre-push hook is disabled. Skipping."
    exit 0
  }
  val=$(yaml_get "hooks.pre-push.scan_secrets") && [[ -n "${val}" ]] && SCAN_SECRETS="${val}"
  val=$(yaml_get "hooks.pre-push.scan_dependencies") && [[ -n "${val}" ]] && SCAN_DEPS="${val}"

  val=$(yaml_get "hooks.pre-push.max_file_size") && [[ -n "${val}" ]] && MAX_FILE_SIZE=$(parse_size "${val}")

  # Load the per-file exclusion list. Without this the documented
  # hooks.pre-push.ignore key was never read, so a false positive in a doc or
  # fixture file had no escape hatch short of --no-verify.
  local patterns
  patterns=$(yaml_get_list "ignore" 2>/dev/null || true)
  if [[ -n "${patterns}" ]]; then
    while IFS= read -r pattern; do
      [[ -n "${pattern}" ]] && IGNORE_PATTERNS+=("${pattern}")
    done <<< "${patterns}"
  fi
}

# --- Secret Patterns ---
# Built-in patterns for common secrets and credentials.

# shellcheck disable=SC2016  # '\$' in the hash patterns is a regex literal
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

  # OpenAI. The legacy shape plus the current prefixed keys: 'sk-proj-',
  # 'sk-svcacct-' and 'sk-admin-' carry '-' and '_', so the legacy pattern,
  # which needs 20 alphanumerics straight after 'sk-', never matched them.
  'sk-[a-zA-Z0-9]{20,}'
  'sk-(proj|svcacct|admin)-[A-Za-z0-9_-]{20,}'

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

  # Generic patterns.
  # NOTE: "'\''" is the portable way to embed a literal single quote inside a
  # single-quoted string. The regex must accept both " and ' as the quote
  # char. A previous "\x27" is NOT an escape grep understands -- it landed in
  # the class as the literal chars \ x 2 7, so single-quoted secrets were
  # never matched at all.
  #
  # The key may itself be quoted and the separator may be ':' as well as '=',
  # so JSON ("password": "...") and YAML (password: '...') assignments match
  # too. scripts/benchmark.sh found the '='-only form missed every JSON config
  # in its corpus. The value must still be quoted and 8+ characters, which is
  # what keeps 'password = os.environ[...]' and short placeholders out.
  'password["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{8,}["'\'']'
  'secret["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{8,}["'\'']'
  'api_key["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{8,}["'\'']'
  'apikey["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{8,}["'\'']'
  'access_token["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{8,}["'\'']'
  '(auth|oauth)_token["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{8,}["'\'']'
  'private_key["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{8,}["'\'']'

  # Private keys: PEM of any type (RSA, EC, DSA, OPENSSH, ENCRYPTED, PGP) and
  # PuTTY .ppk files
  '-----BEGIN ([A-Z]+ )*PRIVATE KEY( BLOCK)?-----'
  'PuTTY-User-Key-File-[0-9]+:'

  # Connection strings
  'mongodb(\+srv)?://[a-zA-Z0-9._%-]+:[a-zA-Z0-9._%-]+@'
  'postgres(ql)?://[a-zA-Z0-9._%-]+:[a-zA-Z0-9._%-]+@'
  'mysql://[a-zA-Z0-9._%-]+:[a-zA-Z0-9._%-]+@'
  'redis://[a-zA-Z0-9._%-]*:[a-zA-Z0-9._%-]+@'
  # user:password@ in a web, file-transfer or mail URL (.git-credentials,
  # pip or npm registry URLs, SMTP settings). The password needs 6+ characters
  # and no template syntax, which drops the 'user:pass@host' examples and
  # '{USER}:{PASSWORD}@' f-strings that fill HTTP client docs and tests.
  '(https?|s?ftp|smtps?|imaps?|amqps?)://[^/[:space:]:]+:[^/[:space:]{}$<>]{6,}@[A-Za-z0-9.-]+'

  # Registry and tool credentials. The npm keys must open the line or follow
  # the registry's ':' (//registry.npmjs.org/:_authToken=...), so code such as
  # 'old_auth = requests...' or 'this._authToken = token' is not matched.
  '(^|[[:space:]:])_authToken[[:space:]]*=[[:space:]]*[^$[:space:]][^[:space:]]{7,}'
  '(^|[[:space:]:])_auth[[:space:]]*=[[:space:]]*[A-Za-z0-9+/=]{8,}'
  '"auth"[[:space:]]*:[[:space:]]*"[A-Za-z0-9+/=]{16,}"'
  'machine[[:space:]]+[^[:space:]]+[[:space:]]+login[[:space:]]+[^[:space:]]+[[:space:]]+password[[:space:]]+[^[:space:]]{6,}'
  'APP_KEY=base64:[A-Za-z0-9+/=]{32,}'

  # Unix password hashes: crypt MD5, SHA-256, SHA-512, Apache apr1, bcrypt
  '\$(1|5|6|apr1)\$[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{22,}'
  '\$2[abxy]?\$[0-9]{2}\$[./A-Za-z0-9]{53}'
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
  "OpenAI Project/Service Key"
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
  "PuTTY Private Key File"
  "MongoDB Connection String"
  "PostgreSQL Connection String"
  "MySQL Connection String"
  "Redis Connection String"
  "Password in URL"
  "npm Auth Token"
  "npm Legacy Auth"
  "Docker Registry Auth"
  "netrc Password"
  "Laravel APP_KEY"
  "Unix Password Hash"
  "bcrypt Password Hash"
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

# True when a file should be excluded from the secret scan, either by the
# built-in binary/lockfile skip list or by hooks.pre-push.ignore in the config.
should_skip_file() {
  local file="$1"

  for pattern in "${SECRET_SCAN_SKIP_FILES[@]}"; do
    # shellcheck disable=SC2254
    case "${file}" in
      ${pattern}) return 0 ;;
    esac
  done

  # Guard the expansion: IGNORE_PATTERNS is empty when no config file exists,
  # and bash 3.2 (macOS system bash) treats "${empty[@]}" as unbound under -u.
  if [[ "${#IGNORE_PATTERNS[@]}" -gt 0 ]]; then
    for pattern in "${IGNORE_PATTERNS[@]}"; do
      # shellcheck disable=SC2254
      case "${file}" in
        ${pattern}) return 0 ;;
      esac
    done
  fi

  return 1
}

# Read a unified diff on stdin and print every added line as
#   <path> TAB <line number in the new file> TAB <line text>
# The path comes from the '+++ b/<path>' header and the line number from the
# '+<start>' of each '@@' hunk header. Header lines are only taken as headers
# between 'diff --git' and the first hunk, so an added line that itself starts
# with '+++' is still scanned as content. git ends the '+++' line with a tab
# when the path contains a space, so that is trimmed. POSIX awk only: it runs
# on the macOS system awk too.
added_lines_with_location() {
  awk '
    /^diff --git / { in_header = 1; path = ""; next }
    in_header && /^\+\+\+ / {
      path = substr($0, 5)
      sub(/^b\//, "", path)
      sub(/\t$/, "", path)
      next
    }
    /^@@ / {
      in_header = 0
      if (match($0, /\+[0-9]+/)) {
        line = substr($0, RSTART + 1, RLENGTH - 1) + 0
      }
      next
    }
    in_header { next }
    /^\+/ { printf "%s\t%d\t%s\n", path, line, substr($0, 2); line++; next }
    /^ / { line++ }
  '
}

scan_secrets_in_range() {
  local range="$1"

  if [[ "${SCAN_SECRETS}" != "true" ]]; then
    print_debug "Secret scanning disabled."
    return
  fi

  print_info "Scanning for secrets..."

  # Build the list of files to scan, dropping anything on the skip list or the
  # configured ignore list, then diff only those paths. Filtering the file list
  # (rather than the assembled diff text) is what makes the documented
  # hooks.pre-push.ignore key take effect.
  local files
  # quotePath=false keeps non-ASCII paths literal, so they still work as
  # pathspecs below instead of arriving as quoted octal escapes
  files=$(git -c core.quotePath=false diff --name-only "${range}" 2>/dev/null || true)

  if [[ -z "${files}" ]]; then
    print_debug "No changed files to scan."
    return
  fi

  local scan_paths=()
  local file
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    if should_skip_file "${file}"; then
      print_debug "Skipping (ignored): ${file}"
      continue
    fi
    scan_paths+=("${file}")
  done <<< "${files}"

  if [[ "${#scan_paths[@]}" -eq 0 ]]; then
    print_pass "No secrets detected (all changed files are on the ignore list)."
    return
  fi

  # One record per added line: <path> TAB <line in the pushed file> TAB <text>.
  # Tracking the path and the hunk's new-file line number is what lets a
  # finding say where the secret is; grepping the raw diff only gave the
  # position inside the diff text, which points at nothing the user can open.
  local added_lines
  added_lines=$(git -c core.quotePath=false diff --no-color --no-ext-diff -U0 \
    --src-prefix=a/ --dst-prefix=b/ "${range}" -- "${scan_paths[@]}" 2>/dev/null \
    | added_lines_with_location || true)

  if [[ -z "${added_lines}" ]]; then
    print_debug "No diff content to scan."
    return
  fi

  local found_secrets=0
  local tab=$'\t'

  for i in "${!SECRET_PATTERNS[@]}"; do
    local pattern="${SECRET_PATTERNS[$i]}"
    local name="${SECRET_NAMES[$i]}"

    # Match after the path field, so a path cannot trigger a pattern. The tab
    # before the text is left inside '.*' so that a pattern opening with
    # (^|[[:space:]]) can still match at the start of the line text.
    local matches
    matches=$(echo "${added_lines}" | grep -E "^[^${tab}]*${tab}[0-9]+.*${pattern}" 2>/dev/null || true)

    if [[ -n "${matches}" ]]; then
      while IFS= read -r match; do
        [[ -z "${match}" ]] && continue

        local match_path match_line line_content
        IFS="${tab}" read -r match_path match_line line_content <<< "${match}"

        # Mask the matched secret value.
        # Use a control-char delimiter: several patterns (connection strings)
        # contain '/', which would break a "s/.../" sed command and, under
        # 'set -e', abort the whole scan before the finding is even reported.
        local masked sed_delim
        sed_delim=$(printf '\001')
        masked=$(echo "${line_content}" | sed -E "s${sed_delim}${pattern}${sed_delim}***REDACTED***${sed_delim}g" | head -c 120)

        print_critical "Possible ${name} found in ${match_path}:${match_line}"
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
  files=$(git -c core.quotePath=false diff --name-only --diff-filter=ACMR "${range}" 2>/dev/null || true)

  if [[ -z "${files}" ]]; then
    print_debug "No files to check."
    return
  fi

  local found_large=0
  # Measure the blob in the commit being pushed, not the working-tree file.
  # 'wc -c < file' measured whatever was checked out, so pushing another branch
  # sized the wrong content and a file deleted locally was skipped entirely.
  local to_ref="${range##*..}"

  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue

    local file_size
    file_size=$(git cat-file -s "${to_ref}:${file}" 2>/dev/null || echo "0")

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

# Run every scan against one <base>..<tip> range
scan_range() {
  local range="$1"

  print_info "Scanning commits: ${range}"
  echo ""

  scan_secrets_in_range "${range}"
  echo ""

  scan_large_files "${range}"
  echo ""

  if [[ "${DRY_RUN}" != "1" ]]; then
    scan_dependencies
    echo ""
  fi
}

main() {
  print_header
  load_config

  if [[ "${DRY_RUN}" == "1" ]]; then
    print_info "Dry-run mode: skipping the dependency audit."
    print_info "Secret and large-file scanning still run and can still block."
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
      local commit_list
      commit_list=$(git log --oneline "${local_sha}" --not --remotes 2>/dev/null || true)
      if [[ -z "${commit_list}" ]]; then
        print_info "No new commits to scan."
        continue
      fi
      # Diff from the commit where the new work leaves already-pushed history.
      # rev-list --boundary marks that commit with a leading '-'. When there is
      # none (the first push of a repo, nothing on any remote yet), diff from
      # the empty tree so every pushed file is scanned.
      #
      # This used to be merge-base(HEAD, @{upstream} or HEAD~10), falling back
      # to ${local_sha}~10. A new branch has no upstream, and a repo with fewer
      # than 11 commits has no HEAD~10, so the range was invalid, git diff
      # failed silently, and the first push of a small repo reported "All
      # checks passed" with a key in it. On longer histories it scanned only
      # the last 10 commits of HEAD, which is not even the branch being pushed.
      local base
      base=$(git rev-list --boundary "${local_sha}" --not --remotes 2>/dev/null | sed -n 's/^-//p' | head -1 || true)
      if [[ -z "${base}" ]]; then
        base=$(git hash-object -t tree /dev/null)
      fi
      range="${base}..${local_sha}"
    else
      range="${remote_sha}..${local_sha}"
    fi

    scan_range "${range}"
  done

  # Run by the pre-commit framework (https://pre-commit.com). It reads git's
  # ref lines itself and hands the hook the range as environment variables.
  # When the push includes the root commit it sets no range at all, only the
  # local branch, so scan that branch from the empty tree.
  if [[ "${has_input}" -eq 0 ]] && [[ -n "${PRE_COMMIT_TO_REF:-}" ]]; then
    has_input=1
    scan_range "${PRE_COMMIT_FROM_REF:-$(git hash-object -t tree /dev/null)}..${PRE_COMMIT_TO_REF}"
  elif [[ "${has_input}" -eq 0 ]] && [[ -n "${PRE_COMMIT_REMOTE_NAME:-}" ]]; then
    has_input=1
    scan_range "$(git hash-object -t tree /dev/null)..${PRE_COMMIT_LOCAL_BRANCH:-HEAD}"
  fi

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
