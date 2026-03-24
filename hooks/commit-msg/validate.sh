#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Commit Message Validator - Commit-Msg Hook
# ============================================================================
# Validates commit messages against conventional commit format.
# If the message is invalid, optionally uses AI to suggest a fix.
#
# Arguments (passed by git):
#   $1 - Path to the file containing the commit message
#
# Exit codes:
#   0 - Commit message is valid
#   1 - Commit message is invalid (commit blocked)
#
# Environment:
#   ANTHROPIC_API_KEY  - Required for Claude provider (for suggestions)
#   OPENAI_API_KEY     - Required for OpenAI provider
#   OLLAMA_HOST        - Ollama server URL
#   AI_HOOKS_DRY_RUN   - Set to "1" to skip API calls
#   AI_HOOKS_DEBUG      - Set to "1" for verbose output
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
  echo -e "${BOLD}${BLUE}  Commit Message Validator${RESET}"
  echo -e "${BOLD}${BLUE}======================================${RESET}"
  echo ""
}

print_pass()  { echo -e "${GREEN}[PASS]${RESET} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${RESET} $1"; }
print_error() { echo -e "${RED}[ERROR]${RESET} $1"; }
print_info()  { echo -e "${CYAN}[INFO]${RESET} $1"; }
print_debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    echo -e "${DIM}[DEBUG] $1${RESET}"
  fi
}

# --- Arguments ---
COMMIT_MSG_FILE="${1:-}"

if [[ -z "${COMMIT_MSG_FILE}" ]] || [[ ! -f "${COMMIT_MSG_FILE}" ]]; then
  print_error "No commit message file provided or file not found."
  exit 1
fi

# --- Configuration ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG_FILE="${REPO_ROOT}/.ai-hooks.yml"

PROVIDER="claude"
MODEL=""
MAX_TOKENS="256"
TIMEOUT="30"
CONVENTION="conventional"
MAX_LENGTH="72"
ALLOWED_TYPES="feat fix docs style refactor perf test build ci chore revert"
SUGGEST_FIX="true"
DRY_RUN="${AI_HOOKS_DRY_RUN:-0}"
DEBUG="${AI_HOOKS_DEBUG:-0}"

yaml_get() {
  local key="$1"
  local file="${CONFIG_FILE}"

  if [[ ! -f "${file}" ]]; then
    return 1
  fi

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

yaml_get_list() {
  local section_key="$1"
  local file="${CONFIG_FILE}"

  [[ ! -f "${file}" ]] && return 1

  local block
  block=$(sed -n '/commit-msg:/,/^  [a-z]/p' "${file}" | sed -n "/    ${section_key}:/,/^    [a-z]/p")
  echo "${block}" | grep '^ *- ' | sed 's/^ *- *//' | sed 's/"//g' | sed "s/'//g"
}

load_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    print_debug "No .ai-hooks.yml found. Using defaults."
    return
  fi

  local val

  val=$(yaml_get "provider") && [[ -n "${val}" ]] && PROVIDER="${val}"
  val=$(yaml_get "model") && [[ -n "${val}" ]] && MODEL="${val}"
  val=$(yaml_get "timeout") && [[ -n "${val}" ]] && TIMEOUT="${val}"
  val=$(yaml_get "dry_run") && [[ "${val}" == "true" ]] && DRY_RUN="1"
  val=$(yaml_get "debug") && [[ "${val}" == "true" ]] && DEBUG="1"

  # Hook-specific
  val=$(yaml_get "hooks.commit-msg.enabled") && [[ "${val}" == "false" ]] && {
    print_debug "commit-msg hook is disabled. Skipping."
    exit 0
  }
  val=$(yaml_get "hooks.commit-msg.convention") && [[ -n "${val}" ]] && CONVENTION="${val}"
  val=$(yaml_get "hooks.commit-msg.max_length") && [[ -n "${val}" ]] && MAX_LENGTH="${val}"
  val=$(yaml_get "hooks.commit-msg.suggest_fix") && [[ -n "${val}" ]] && SUGGEST_FIX="${val}"

  # Load allowed types
  local types_list
  types_list=$(yaml_get_list "allowed_types" 2>/dev/null || true)
  if [[ -n "${types_list}" ]]; then
    ALLOWED_TYPES=$(echo "${types_list}" | tr '\n' ' ')
  fi

  if [[ -z "${MODEL}" ]]; then
    case "${PROVIDER}" in
      claude)  MODEL="claude-sonnet-4-6" ;;
      openai)  MODEL="gpt-4o" ;;
      ollama)  MODEL="llama3.1" ;;
    esac
  fi
}

# --- Validation ---

# Read the commit message, stripping comment lines and leading/trailing whitespace
read_commit_message() {
  local msg_file="$1"
  # Remove lines starting with # (git comments) and trim
  grep -v '^#' "${msg_file}" | sed '/^$/{ N; /^\n$/d; }' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

validate_conventional() {
  local message="$1"
  local errors=()

  # Get the subject line (first non-empty line)
  local subject
  subject=$(echo "${message}" | head -1)

  if [[ -z "${subject}" ]]; then
    errors+=("Commit message is empty.")
    printf '%s\n' "${errors[@]}"
    return 1
  fi

  # Check conventional commit format: type(scope): description  or  type: description
  local cc_regex="^([a-z]+)(\([a-z0-9._-]+\))?!?: .+"
  if ! [[ "${subject}" =~ ${cc_regex} ]]; then
    errors+=("Subject does not match conventional commit format: type(scope): description")
  else
    # Check that the type is allowed
    local msg_type="${BASH_REMATCH[1]}"
    local type_valid=0
    for allowed in ${ALLOWED_TYPES}; do
      if [[ "${msg_type}" == "${allowed}" ]]; then
        type_valid=1
        break
      fi
    done

    if [[ "${type_valid}" -eq 0 ]]; then
      errors+=("Type '${msg_type}' is not allowed. Use one of: ${ALLOWED_TYPES}")
    fi
  fi

  # Check subject length
  local subject_len=${#subject}
  if [[ "${subject_len}" -gt "${MAX_LENGTH}" ]]; then
    errors+=("Subject line is ${subject_len} characters (max: ${MAX_LENGTH}).")
  fi

  # Check that subject doesn't end with a period
  if [[ "${subject}" == *. ]]; then
    errors+=("Subject line should not end with a period.")
  fi

  # Check that subject uses lowercase after the colon
  local after_colon
  after_colon=$(echo "${subject}" | sed 's/^[^:]*: *//')
  if [[ -n "${after_colon}" ]] && [[ "${after_colon}" =~ ^[A-Z] ]]; then
    errors+=("Description after the colon should start with lowercase.")
  fi

  # Check second line is blank (if there are more lines)
  local line_count
  line_count=$(echo "${message}" | wc -l)
  if [[ "${line_count}" -gt 1 ]]; then
    local second_line
    second_line=$(echo "${message}" | sed -n '2p')
    if [[ -n "${second_line}" ]]; then
      errors+=("Second line must be blank (separates subject from body).")
    fi
  fi

  if [[ ${#errors[@]} -gt 0 ]]; then
    printf '%s\n' "${errors[@]}"
    return 1
  fi

  return 0
}

validate_simple() {
  local message="$1"
  local errors=()

  local subject
  subject=$(echo "${message}" | head -1)

  if [[ -z "${subject}" ]]; then
    errors+=("Commit message is empty.")
    printf '%s\n' "${errors[@]}"
    return 1
  fi

  # Minimum length
  if [[ ${#subject} -lt 10 ]]; then
    errors+=("Subject is too short (${#subject} chars). Write a meaningful message (min 10 chars).")
  fi

  # Maximum length
  if [[ ${#subject} -gt "${MAX_LENGTH}" ]]; then
    errors+=("Subject is too long (${#subject} chars, max: ${MAX_LENGTH}).")
  fi

  if [[ ${#errors[@]} -gt 0 ]]; then
    printf '%s\n' "${errors[@]}"
    return 1
  fi

  return 0
}

# --- AI Suggestion ---

get_ai_suggestion() {
  local original_msg="$1"
  local validation_errors="$2"

  local prompt
  prompt="The following commit message is invalid:

\"${original_msg}\"

Validation errors:
${validation_errors}

Suggest a corrected commit message that follows the Conventional Commits format (type(scope): description).
Allowed types: ${ALLOWED_TYPES}
Maximum subject length: ${MAX_LENGTH} characters.

Respond with ONLY the corrected commit message. No explanations, no quotes, no markdown."

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "fix: corrected commit message"
    return 0
  fi

  if ! command -v jq &>/dev/null; then
    print_debug "jq not available, skipping AI suggestion."
    return 1
  fi

  case "${PROVIDER}" in
    claude)
      local api_key="${ANTHROPIC_API_KEY:-}"
      [[ -z "${api_key}" ]] && return 1

      local payload
      payload=$(jq -n \
        --arg model "${MODEL}" \
        --argjson max_tokens "${MAX_TOKENS}" \
        --arg prompt "${prompt}" \
        '{ model: $model, max_tokens: $max_tokens, messages: [{ role: "user", content: $prompt }] }')

      local response
      response=$(curl -s --max-time "${TIMEOUT}" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${api_key}" \
        -H "anthropic-version: 2023-06-01" \
        -d "${payload}" \
        "https://api.anthropic.com/v1/messages" 2>/dev/null) || return 1

      echo "${response}" | jq -r '.content[0].text // empty' 2>/dev/null
      ;;
    openai)
      local api_key="${OPENAI_API_KEY:-}"
      [[ -z "${api_key}" ]] && return 1

      local payload
      payload=$(jq -n \
        --arg model "${MODEL}" \
        --argjson max_tokens "${MAX_TOKENS}" \
        --arg prompt "${prompt}" \
        '{ model: $model, max_tokens: $max_tokens, messages: [{ role: "user", content: $prompt }] }')

      local response
      response=$(curl -s --max-time "${TIMEOUT}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${api_key}" \
        -d "${payload}" \
        "https://api.openai.com/v1/chat/completions" 2>/dev/null) || return 1

      echo "${response}" | jq -r '.choices[0].message.content // empty' 2>/dev/null
      ;;
    ollama)
      local host="${OLLAMA_HOST:-http://localhost:11434}"

      local payload
      payload=$(jq -n \
        --arg model "${MODEL}" \
        --arg prompt "${prompt}" \
        '{ model: $model, prompt: $prompt, stream: false }')

      local response
      response=$(curl -s --max-time "${TIMEOUT}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${host}/api/generate" 2>/dev/null) || return 1

      echo "${response}" | jq -r '.response // empty' 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

# --- Main ---

main() {
  print_header
  load_config

  # 1. Read the commit message
  local commit_msg
  commit_msg=$(read_commit_message "${COMMIT_MSG_FILE}")

  print_debug "Commit message: ${commit_msg}"

  if [[ -z "${commit_msg}" ]]; then
    print_error "Commit message is empty."
    echo ""
    print_info "Write a meaningful commit message and try again."
    exit 1
  fi

  # 2. Validate based on convention
  local validation_errors=""
  local is_valid=0

  case "${CONVENTION}" in
    conventional)
      validation_errors=$(validate_conventional "${commit_msg}" 2>&1) && is_valid=1 || is_valid=0
      ;;
    simple)
      validation_errors=$(validate_simple "${commit_msg}" 2>&1) && is_valid=1 || is_valid=0
      ;;
    *)
      print_warn "Unknown convention '${CONVENTION}'. Skipping validation."
      exit 0
      ;;
  esac

  # 3. Handle results
  if [[ "${is_valid}" -eq 1 ]]; then
    print_pass "Commit message is valid."
    echo ""
    exit 0
  fi

  # Show errors
  print_error "Commit message validation failed."
  echo ""
  echo -e "${BOLD}Message:${RESET} \"${commit_msg}\""
  echo ""
  echo -e "${BOLD}Errors:${RESET}"
  while IFS= read -r err; do
    [[ -n "${err}" ]] && echo -e "  ${RED}-${RESET} ${err}"
  done <<< "${validation_errors}"
  echo ""

  # 4. Get AI suggestion if enabled
  if [[ "${SUGGEST_FIX}" == "true" ]]; then
    print_info "Asking AI for a suggested fix..."

    local suggestion
    suggestion=$(get_ai_suggestion "${commit_msg}" "${validation_errors}" 2>/dev/null || true)

    if [[ -n "${suggestion}" ]]; then
      # Clean up the suggestion
      suggestion=$(echo "${suggestion}" | sed 's/^```[a-z]*$//' | sed 's/^```$//' | sed 's/^"//;s/"$//' | head -5)
      echo -e "${BOLD}Suggested message:${RESET}"
      echo -e "  ${GREEN}${suggestion}${RESET}"
      echo ""
    fi
  fi

  print_info "Fix your commit message and try again."
  print_info "Use 'git commit --no-verify' to bypass this check."
  exit 1
}

main "$@"
