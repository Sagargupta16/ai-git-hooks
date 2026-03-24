#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# AI Code Review - Pre-Commit Hook
# ============================================================================
# Reviews staged changes using AI (Claude/OpenAI/Ollama) and reports bugs,
# security issues, and anti-patterns before they are committed.
#
# Exit codes:
#   0 - No blocking issues found (commit proceeds)
#   1 - Blocking issues found or fatal error (commit blocked)
#
# Environment:
#   ANTHROPIC_API_KEY  - Required for Claude provider
#   OPENAI_API_KEY     - Required for OpenAI provider
#   OLLAMA_HOST        - Ollama server URL (default: http://localhost:11434)
#   AI_HOOKS_DRY_RUN   - Set to "1" to skip API calls and use mock responses
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

# --- Utility Functions ---

print_header() {
  echo ""
  echo -e "${BOLD}${BLUE}======================================${RESET}"
  echo -e "${BOLD}${BLUE}  AI Code Review (pre-commit)${RESET}"
  echo -e "${BOLD}${BLUE}======================================${RESET}"
  echo ""
}

print_pass() {
  echo -e "${GREEN}[PASS]${RESET} $1"
}

print_warn() {
  echo -e "${YELLOW}[WARN]${RESET} $1"
}

print_error() {
  echo -e "${RED}[ERROR]${RESET} $1"
}

print_info() {
  echo -e "${CYAN}[INFO]${RESET} $1"
}

print_debug() {
  if [[ "${AI_HOOKS_DEBUG:-0}" == "1" ]]; then
    echo -e "${DIM}[DEBUG] $1${RESET}"
  fi
}

# --- Configuration Loading ---
# Reads .ai-hooks.yml using basic shell parsing (no external YAML library).
# Falls back to sensible defaults if config is missing.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG_FILE="${REPO_ROOT}/.ai-hooks.yml"

# Defaults
PROVIDER="claude"
MODEL=""
MAX_TOKENS="1024"
TIMEOUT="30"
SEVERITY="error"
MAX_FILES="20"
MAX_DIFF_LINES="500"
CUSTOM_PROMPT=""
IGNORE_PATTERNS=()
DRY_RUN="${AI_HOOKS_DRY_RUN:-0}"
DEBUG="${AI_HOOKS_DEBUG:-0}"

# Simple YAML value reader: reads a top-level or nested key from the config.
# Usage: yaml_get "key" or yaml_get "parent.child"
yaml_get() {
  local key="$1"
  local file="${CONFIG_FILE}"

  if [[ ! -f "${file}" ]]; then
    return 1
  fi

  # Handle dotted keys like "hooks.pre-commit.severity"
  if [[ "${key}" == *.* ]]; then
    local parent="${key%%.*}"
    local child="${key#*.}"
    # Simple nested lookup: find lines after parent, get the child value
    if [[ "${child}" == *.* ]]; then
      local mid="${child%%.*}"
      local leaf="${child#*.}"
      sed -n "/^${parent}:/,/^[^ ]/p" "${file}" \
        | sed -n "/^  ${mid}:/,/^  [^ ]/p" \
        | grep "^    ${leaf}:" \
        | head -1 \
        | sed 's/^[^:]*: *//' \
        | sed 's/^ *"//' \
        | sed 's/" *$//' \
        | sed "s/^ *'//" \
        | sed "s/' *$//"
    else
      sed -n "/^${parent}:/,/^[^ ]/p" "${file}" \
        | grep "^  ${child}:" \
        | head -1 \
        | sed 's/^[^:]*: *//' \
        | sed 's/^ *"//' \
        | sed 's/" *$//' \
        | sed "s/^ *'//" \
        | sed "s/' *$//"
    fi
  else
    grep "^${key}:" "${file}" \
      | head -1 \
      | sed 's/^[^:]*: *//' \
      | sed 's/^ *"//' \
      | sed 's/" *$//' \
      | sed "s/^ *'//" \
      | sed "s/' *$//"
  fi
}

# Read list values (lines starting with "- " under a key)
yaml_get_list() {
  local section_key="$1"
  local file="${CONFIG_FILE}"

  if [[ ! -f "${file}" ]]; then
    return 1
  fi

  # Navigate to the section, extract list items
  local in_section=0
  local depth=0

  # For "hooks.pre-commit.ignore" we need nested parsing
  # Simplified approach: search for the ignore block under pre-commit
  local block
  block=$(sed -n '/pre-commit:/,/^  [a-z]/p' "${file}" | sed -n "/    ${section_key}:/,/^    [a-z]/p")
  echo "${block}" | grep '^ *- ' | sed 's/^ *- *//' | sed 's/"//g' | sed "s/'//g"
}

load_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    print_info "No .ai-hooks.yml found. Using defaults."
    return
  fi

  print_debug "Loading config from ${CONFIG_FILE}"

  local val

  val=$(yaml_get "provider") && [[ -n "${val}" ]] && PROVIDER="${val}"
  val=$(yaml_get "model") && [[ -n "${val}" ]] && MODEL="${val}"
  val=$(yaml_get "max_tokens") && [[ -n "${val}" ]] && MAX_TOKENS="${val}"
  val=$(yaml_get "timeout") && [[ -n "${val}" ]] && TIMEOUT="${val}"
  val=$(yaml_get "dry_run") && [[ "${val}" == "true" ]] && DRY_RUN="1"
  val=$(yaml_get "debug") && [[ "${val}" == "true" ]] && DEBUG="1"

  # Hook-specific settings
  val=$(yaml_get "hooks.pre-commit.enabled") && [[ "${val}" == "false" ]] && {
    print_info "Pre-commit hook is disabled in config. Skipping."
    exit 0
  }
  val=$(yaml_get "hooks.pre-commit.severity") && [[ -n "${val}" ]] && SEVERITY="${val}"
  val=$(yaml_get "hooks.pre-commit.max_files") && [[ -n "${val}" ]] && MAX_FILES="${val}"
  val=$(yaml_get "hooks.pre-commit.max_diff_lines") && [[ -n "${val}" ]] && MAX_DIFF_LINES="${val}"
  val=$(yaml_get "hooks.pre-commit.custom_prompt") && [[ -n "${val}" ]] && CUSTOM_PROMPT="${val}"

  # Load ignore patterns
  local patterns
  patterns=$(yaml_get_list "ignore" 2>/dev/null || true)
  if [[ -n "${patterns}" ]]; then
    while IFS= read -r pattern; do
      [[ -n "${pattern}" ]] && IGNORE_PATTERNS+=("${pattern}")
    done <<< "${patterns}"
  fi

  # Set default models per provider
  if [[ -z "${MODEL}" ]]; then
    case "${PROVIDER}" in
      claude)  MODEL="claude-sonnet-4-6" ;;
      openai)  MODEL="gpt-4o" ;;
      ollama)  MODEL="llama3.1" ;;
    esac
  fi

  print_debug "Provider: ${PROVIDER}, Model: ${MODEL}, Severity: ${SEVERITY}"
}

# --- Staged Files Collection ---

get_staged_files() {
  git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true
}

filter_ignored_files() {
  local files="$1"
  local filtered=""

  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    local ignored=0

    for pattern in "${IGNORE_PATTERNS[@]}"; do
      # Simple glob matching
      # shellcheck disable=SC2254
      case "${file}" in
        ${pattern}) ignored=1; break ;;
      esac
    done

    if [[ "${ignored}" -eq 0 ]]; then
      filtered="${filtered}${file}"$'\n'
    else
      print_debug "Ignoring: ${file} (matched pattern)"
    fi
  done <<< "${files}"

  echo "${filtered}"
}

# --- API Call Functions ---

call_claude() {
  local diff_content="$1"
  local api_key="${ANTHROPIC_API_KEY:-}"

  if [[ -z "${api_key}" ]]; then
    print_error "ANTHROPIC_API_KEY is not set."
    print_info "Export your key: export ANTHROPIC_API_KEY=\"sk-ant-...\""
    return 1
  fi

  local prompt
  prompt="You are a senior code reviewer. Review the following git diff for:
1. Bugs and logic errors
2. Security vulnerabilities (XSS, SQL injection, command injection, etc.)
3. Performance anti-patterns
4. Missing error handling

For each issue found, respond in this exact format (one per line):
SEVERITY|FILE:LINE|DESCRIPTION|SUGGESTION

Where SEVERITY is one of: ERROR, WARNING, INFO
If no issues are found, respond with exactly: NO_ISSUES

Do not include any other text, explanations, or markdown formatting.
${CUSTOM_PROMPT:+Additional instructions: ${CUSTOM_PROMPT}}

Git diff to review:
${diff_content}"

  local payload
  payload=$(jq -n \
    --arg model "${MODEL}" \
    --argjson max_tokens "${MAX_TOKENS}" \
    --arg prompt "${prompt}" \
    '{
      model: $model,
      max_tokens: $max_tokens,
      messages: [{ role: "user", content: $prompt }]
    }')

  print_debug "Calling Claude API (model: ${MODEL})..."

  local response
  response=$(curl -s --max-time "${TIMEOUT}" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${api_key}" \
    -H "anthropic-version: 2023-06-01" \
    -d "${payload}" \
    "https://api.anthropic.com/v1/messages" 2>/dev/null) || {
    print_error "Network error: Failed to reach Claude API."
    print_info "Check your internet connection and try again."
    return 1
  }

  # Check for API errors
  local error_msg
  error_msg=$(echo "${response}" | jq -r '.error.message // empty' 2>/dev/null)
  if [[ -n "${error_msg}" ]]; then
    print_error "Claude API error: ${error_msg}"
    return 1
  fi

  # Extract the text content
  echo "${response}" | jq -r '.content[0].text // empty' 2>/dev/null
}

call_openai() {
  local diff_content="$1"
  local api_key="${OPENAI_API_KEY:-}"

  if [[ -z "${api_key}" ]]; then
    print_error "OPENAI_API_KEY is not set."
    print_info "Export your key: export OPENAI_API_KEY=\"sk-...\""
    return 1
  fi

  local prompt
  prompt="You are a senior code reviewer. Review the following git diff for:
1. Bugs and logic errors
2. Security vulnerabilities (XSS, SQL injection, command injection, etc.)
3. Performance anti-patterns
4. Missing error handling

For each issue found, respond in this exact format (one per line):
SEVERITY|FILE:LINE|DESCRIPTION|SUGGESTION

Where SEVERITY is one of: ERROR, WARNING, INFO
If no issues are found, respond with exactly: NO_ISSUES

Do not include any other text, explanations, or markdown formatting.
${CUSTOM_PROMPT:+Additional instructions: ${CUSTOM_PROMPT}}

Git diff to review:
${diff_content}"

  local payload
  payload=$(jq -n \
    --arg model "${MODEL}" \
    --argjson max_tokens "${MAX_TOKENS}" \
    --arg prompt "${prompt}" \
    '{
      model: $model,
      max_tokens: $max_tokens,
      messages: [{ role: "user", content: $prompt }]
    }')

  print_debug "Calling OpenAI API (model: ${MODEL})..."

  local response
  response=$(curl -s --max-time "${TIMEOUT}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${api_key}" \
    -d "${payload}" \
    "https://api.openai.com/v1/chat/completions" 2>/dev/null) || {
    print_error "Network error: Failed to reach OpenAI API."
    print_info "Check your internet connection and try again."
    return 1
  }

  local error_msg
  error_msg=$(echo "${response}" | jq -r '.error.message // empty' 2>/dev/null)
  if [[ -n "${error_msg}" ]]; then
    print_error "OpenAI API error: ${error_msg}"
    return 1
  fi

  echo "${response}" | jq -r '.choices[0].message.content // empty' 2>/dev/null
}

call_ollama() {
  local diff_content="$1"
  local host="${OLLAMA_HOST:-http://localhost:11434}"

  local prompt
  prompt="You are a senior code reviewer. Review the following git diff for:
1. Bugs and logic errors
2. Security vulnerabilities (XSS, SQL injection, command injection, etc.)
3. Performance anti-patterns
4. Missing error handling

For each issue found, respond in this exact format (one per line):
SEVERITY|FILE:LINE|DESCRIPTION|SUGGESTION

Where SEVERITY is one of: ERROR, WARNING, INFO
If no issues are found, respond with exactly: NO_ISSUES

Do not include any other text, explanations, or markdown formatting.
${CUSTOM_PROMPT:+Additional instructions: ${CUSTOM_PROMPT}}

Git diff to review:
${diff_content}"

  local payload
  payload=$(jq -n \
    --arg model "${MODEL}" \
    --arg prompt "${prompt}" \
    '{
      model: $model,
      prompt: $prompt,
      stream: false
    }')

  print_debug "Calling Ollama (host: ${host}, model: ${MODEL})..."

  local response
  response=$(curl -s --max-time "${TIMEOUT}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${host}/api/generate" 2>/dev/null) || {
    print_error "Network error: Failed to reach Ollama at ${host}."
    print_info "Make sure Ollama is running: ollama serve"
    return 1
  }

  local error_msg
  error_msg=$(echo "${response}" | jq -r '.error // empty' 2>/dev/null)
  if [[ -n "${error_msg}" ]]; then
    print_error "Ollama error: ${error_msg}"
    return 1
  fi

  echo "${response}" | jq -r '.response // empty' 2>/dev/null
}

mock_response() {
  echo "NO_ISSUES"
}

# --- Response Parsing ---

parse_and_display() {
  local response="$1"
  local error_count=0
  local warn_count=0
  local info_count=0

  if [[ -z "${response}" ]]; then
    print_error "Empty response from AI provider."
    return 1
  fi

  # Check for clean bill of health
  if echo "${response}" | grep -qi "NO_ISSUES"; then
    print_pass "No issues found. Code looks good!"
    echo ""
    return 0
  fi

  # Parse structured response lines
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue

    # Expected format: SEVERITY|FILE:LINE|DESCRIPTION|SUGGESTION
    local severity file_loc description suggestion
    severity=$(echo "${line}" | cut -d'|' -f1 | tr -d ' ')
    file_loc=$(echo "${line}" | cut -d'|' -f2 | tr -d ' ')
    description=$(echo "${line}" | cut -d'|' -f3)
    suggestion=$(echo "${line}" | cut -d'|' -f4)

    case "${severity}" in
      ERROR)
        print_error "${file_loc}"
        echo -e "  ${description}"
        [[ -n "${suggestion}" ]] && echo -e "  ${DIM}Fix: ${suggestion}${RESET}"
        ((error_count++)) || true
        ;;
      WARNING)
        print_warn "${file_loc}"
        echo -e "  ${description}"
        [[ -n "${suggestion}" ]] && echo -e "  ${DIM}Fix: ${suggestion}${RESET}"
        ((warn_count++)) || true
        ;;
      INFO)
        print_info "${file_loc}"
        echo -e "  ${description}"
        [[ -n "${suggestion}" ]] && echo -e "  ${DIM}Suggestion: ${suggestion}${RESET}"
        ((info_count++)) || true
        ;;
      *)
        # Lines that don't match the format -- display as-is
        echo -e "  ${DIM}${line}${RESET}"
        ;;
    esac
    echo ""
  done <<< "${response}"

  # Summary
  echo -e "${BOLD}Summary:${RESET} ${RED}${error_count} error(s)${RESET}, ${YELLOW}${warn_count} warning(s)${RESET}, ${CYAN}${info_count} info${RESET}"
  echo ""

  # Decide whether to block based on severity threshold
  case "${SEVERITY}" in
    error)
      if [[ "${error_count}" -gt 0 ]]; then
        print_error "Commit blocked due to ${error_count} error(s)."
        print_info "Fix the issues above or use 'git commit --no-verify' to bypass."
        return 1
      fi
      ;;
    warn)
      if [[ "${error_count}" -gt 0 ]] || [[ "${warn_count}" -gt 0 ]]; then
        print_error "Commit blocked due to ${error_count} error(s) and ${warn_count} warning(s)."
        print_info "Fix the issues above or use 'git commit --no-verify' to bypass."
        return 1
      fi
      ;;
    info)
      if [[ "${error_count}" -gt 0 ]] || [[ "${warn_count}" -gt 0 ]] || [[ "${info_count}" -gt 0 ]]; then
        print_error "Commit blocked (strict mode). ${error_count} error(s), ${warn_count} warning(s), ${info_count} info."
        print_info "Fix the issues above or use 'git commit --no-verify' to bypass."
        return 1
      fi
      ;;
  esac

  return 0
}

# --- Main ---

main() {
  print_header
  load_config

  # 1. Get staged files
  local staged_files
  staged_files=$(get_staged_files)

  if [[ -z "${staged_files}" ]]; then
    print_info "No staged files found. Skipping review."
    exit 0
  fi

  # 2. Filter ignored files
  staged_files=$(filter_ignored_files "${staged_files}")

  if [[ -z "${staged_files}" ]]; then
    print_info "All staged files match ignore patterns. Skipping review."
    exit 0
  fi

  # 3. Count files
  local file_count
  file_count=$(echo "${staged_files}" | grep -c '[^[:space:]]' || true)

  if [[ "${file_count}" -gt "${MAX_FILES}" ]]; then
    print_warn "Too many files staged (${file_count} > ${MAX_FILES}). Skipping AI review."
    print_info "Adjust max_files in .ai-hooks.yml or commit in smaller batches."
    exit 0
  fi

  print_info "Reviewing ${file_count} file(s)..."
  echo -e "${DIM}$(echo "${staged_files}" | sed 's/^/  /')${RESET}"
  echo ""

  # 4. Get the diff
  local diff_content
  diff_content=$(git diff --cached --diff-filter=ACMR 2>/dev/null || true)

  if [[ -z "${diff_content}" ]]; then
    print_info "Empty diff. Skipping review."
    exit 0
  fi

  # Truncate large diffs
  local diff_lines
  diff_lines=$(echo "${diff_content}" | wc -l)
  if [[ "${diff_lines}" -gt "${MAX_DIFF_LINES}" ]]; then
    print_warn "Diff is large (${diff_lines} lines). Truncating to ${MAX_DIFF_LINES} lines."
    diff_content=$(echo "${diff_content}" | head -n "${MAX_DIFF_LINES}")
  fi

  # 5. Call AI provider
  local response=""

  if [[ "${DRY_RUN}" == "1" ]]; then
    print_info "Dry-run mode: Skipping API call."
    response=$(mock_response)
  else
    # Check that jq is available
    if ! command -v jq &>/dev/null; then
      print_error "'jq' is required but not installed."
      print_info "Install it: brew install jq (macOS) or apt install jq (Linux)"
      exit 1
    fi

    case "${PROVIDER}" in
      claude)
        response=$(call_claude "${diff_content}") || exit 1
        ;;
      openai)
        response=$(call_openai "${diff_content}") || exit 1
        ;;
      ollama)
        response=$(call_ollama "${diff_content}") || exit 1
        ;;
      *)
        print_error "Unknown provider: ${PROVIDER}"
        print_info "Supported providers: claude, openai, ollama"
        exit 1
        ;;
    esac
  fi

  # 6. Parse and display results
  parse_and_display "${response}"
}

main "$@"
