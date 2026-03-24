#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Auto Commit Message Generator - Prepare-Commit-Msg Hook
# ============================================================================
# Analyzes staged changes using AI and generates a conventional commit message.
# Detects Jira/Linear ticket numbers from the branch name and prefixes them.
#
# Arguments (passed by git):
#   $1 - Path to the commit message file
#   $2 - Source of the commit message (message, template, merge, squash, commit)
#   $3 - Commit SHA (only for amend)
#
# Exit codes:
#   0 - Message written successfully (or skipped gracefully)
#   1 - Fatal error
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
  echo "" >&2
  echo -e "${BOLD}${BLUE}======================================${RESET}" >&2
  echo -e "${BOLD}${BLUE}  Commit Message Generator${RESET}" >&2
  echo -e "${BOLD}${BLUE}======================================${RESET}" >&2
  echo "" >&2
}

print_pass()  { echo -e "${GREEN}[PASS]${RESET} $1" >&2; }
print_warn()  { echo -e "${YELLOW}[WARN]${RESET} $1" >&2; }
print_error() { echo -e "${RED}[ERROR]${RESET} $1" >&2; }
print_info()  { echo -e "${CYAN}[INFO]${RESET} $1" >&2; }
print_debug() {
  if [[ "${AI_HOOKS_DEBUG:-0}" == "1" ]]; then
    echo -e "${DIM}[DEBUG] $1${RESET}" >&2
  fi
}

# --- Arguments ---
COMMIT_MSG_FILE="${1:-}"
COMMIT_SOURCE="${2:-}"
# COMMIT_SHA="${3:-}"  # unused but received for amend

# If the user provided a message via -m, or this is a merge/squash, skip.
if [[ "${COMMIT_SOURCE}" == "message" ]] || [[ "${COMMIT_SOURCE}" == "merge" ]] || [[ "${COMMIT_SOURCE}" == "squash" ]]; then
  print_debug "Commit source is '${COMMIT_SOURCE}', skipping auto-message."
  exit 0
fi

if [[ -z "${COMMIT_MSG_FILE}" ]]; then
  print_error "No commit message file provided. This hook should be called by git."
  exit 1
fi

# --- Configuration Loading ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG_FILE="${REPO_ROOT}/.ai-hooks.yml"

# Defaults
PROVIDER="claude"
MODEL=""
MAX_TOKENS="512"
TIMEOUT="30"
STYLE="conventional"
TICKET_PREFIX="true"
MAX_LENGTH="72"
CUSTOM_PROMPT=""
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

load_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    print_debug "No .ai-hooks.yml found. Using defaults."
    return
  fi

  local val

  val=$(yaml_get "provider") && [[ -n "${val}" ]] && PROVIDER="${val}"
  val=$(yaml_get "model") && [[ -n "${val}" ]] && MODEL="${val}"
  val=$(yaml_get "max_tokens") && [[ -n "${val}" ]] && MAX_TOKENS="${val}"
  val=$(yaml_get "timeout") && [[ -n "${val}" ]] && TIMEOUT="${val}"
  val=$(yaml_get "dry_run") && [[ "${val}" == "true" ]] && DRY_RUN="1"
  val=$(yaml_get "debug") && [[ "${val}" == "true" ]] && DEBUG="1"

  # Hook-specific
  val=$(yaml_get "hooks.prepare-commit-msg.enabled") && [[ "${val}" == "false" ]] && {
    print_debug "prepare-commit-msg hook is disabled. Skipping."
    exit 0
  }
  val=$(yaml_get "hooks.prepare-commit-msg.style") && [[ -n "${val}" ]] && STYLE="${val}"
  val=$(yaml_get "hooks.prepare-commit-msg.ticket_prefix") && [[ -n "${val}" ]] && TICKET_PREFIX="${val}"
  val=$(yaml_get "hooks.prepare-commit-msg.max_length") && [[ -n "${val}" ]] && MAX_LENGTH="${val}"
  val=$(yaml_get "hooks.prepare-commit-msg.custom_prompt") && [[ -n "${val}" ]] && CUSTOM_PROMPT="${val}"

  if [[ -z "${MODEL}" ]]; then
    case "${PROVIDER}" in
      claude)  MODEL="claude-sonnet-4-6" ;;
      openai)  MODEL="gpt-4o" ;;
      ollama)  MODEL="llama3.1" ;;
    esac
  fi
}

# --- Ticket Detection ---
# Extracts Jira/Linear/GitHub ticket numbers from the current branch name.
# Examples:
#   feature/PROJ-42-add-login   -> PROJ-42
#   PROJ-123/fix-bug            -> PROJ-123
#   fix/gh-456-something        -> #456
#   feature/LINEAR-789          -> LINEAR-789

detect_ticket() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")

  if [[ -z "${branch}" ]]; then
    return
  fi

  print_debug "Branch name: ${branch}"

  # Match Jira/Linear style: PROJ-123
  local ticket
  ticket=$(echo "${branch}" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1) || true

  if [[ -n "${ticket}" ]]; then
    echo "${ticket}"
    return
  fi

  # Match GitHub issue style: gh-123 or #123
  ticket=$(echo "${branch}" | grep -oE 'gh-([0-9]+)' | head -1 | sed 's/gh-/#/') || true

  if [[ -n "${ticket}" ]]; then
    echo "${ticket}"
    return
  fi
}

# --- AI Provider Calls ---

build_prompt() {
  local diff_content="$1"
  local style_instruction=""

  case "${STYLE}" in
    conventional)
      style_instruction="Generate a commit message following the Conventional Commits format:
type(scope): description

Where type is one of: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert
The scope is optional but encouraged if relevant.
Keep the subject line under ${MAX_LENGTH} characters.
If the changes warrant it, add a blank line followed by bullet points explaining what changed."
      ;;
    simple)
      style_instruction="Generate a brief one-line commit message under ${MAX_LENGTH} characters.
Focus on what changed and why. Use imperative mood (e.g., 'Add feature' not 'Added feature')."
      ;;
    detailed)
      style_instruction="Generate a detailed commit message with:
- A subject line under ${MAX_LENGTH} characters in imperative mood
- A blank line
- Bullet points explaining what was changed and why

Use imperative mood (e.g., 'Add feature' not 'Added feature')."
      ;;
  esac

  cat <<PROMPT
You are a commit message generator. Analyze the following git diff and generate an appropriate commit message.

${style_instruction}

IMPORTANT: Respond with ONLY the commit message. No explanations, no quotes, no markdown formatting, no code blocks. Just the raw commit message text.
${CUSTOM_PROMPT:+Additional instructions: ${CUSTOM_PROMPT}}

Git diff:
${diff_content}
PROMPT
}

call_claude() {
  local prompt="$1"
  local api_key="${ANTHROPIC_API_KEY:-}"

  if [[ -z "${api_key}" ]]; then
    print_error "ANTHROPIC_API_KEY is not set."
    print_info "Export your key: export ANTHROPIC_API_KEY=\"sk-ant-...\""
    return 1
  fi

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

  print_debug "Calling Claude API..."

  local response
  response=$(curl -s --max-time "${TIMEOUT}" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${api_key}" \
    -H "anthropic-version: 2023-06-01" \
    -d "${payload}" \
    "https://api.anthropic.com/v1/messages" 2>/dev/null) || {
    print_error "Network error: Failed to reach Claude API."
    return 1
  }

  local error_msg
  error_msg=$(echo "${response}" | jq -r '.error.message // empty' 2>/dev/null)
  if [[ -n "${error_msg}" ]]; then
    print_error "Claude API error: ${error_msg}"
    return 1
  fi

  echo "${response}" | jq -r '.content[0].text // empty' 2>/dev/null
}

call_openai() {
  local prompt="$1"
  local api_key="${OPENAI_API_KEY:-}"

  if [[ -z "${api_key}" ]]; then
    print_error "OPENAI_API_KEY is not set."
    print_info "Export your key: export OPENAI_API_KEY=\"sk-...\""
    return 1
  fi

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

  print_debug "Calling OpenAI API..."

  local response
  response=$(curl -s --max-time "${TIMEOUT}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${api_key}" \
    -d "${payload}" \
    "https://api.openai.com/v1/chat/completions" 2>/dev/null) || {
    print_error "Network error: Failed to reach OpenAI API."
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
  local prompt="$1"
  local host="${OLLAMA_HOST:-http://localhost:11434}"

  local payload
  payload=$(jq -n \
    --arg model "${MODEL}" \
    --arg prompt "${prompt}" \
    '{
      model: $model,
      prompt: $prompt,
      stream: false
    }')

  print_debug "Calling Ollama (host: ${host})..."

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
  echo "feat: update project files"
}

# --- Main ---

main() {
  print_header
  load_config

  # 1. Get staged diff
  local diff_content
  diff_content=$(git diff --cached 2>/dev/null || true)

  if [[ -z "${diff_content}" ]]; then
    print_info "No staged changes. Skipping message generation."
    exit 0
  fi

  # Truncate very large diffs (keep first 500 lines)
  local diff_lines
  diff_lines=$(echo "${diff_content}" | wc -l)
  if [[ "${diff_lines}" -gt 500 ]]; then
    print_warn "Large diff (${diff_lines} lines). Truncating to 500 lines for AI."
    diff_content=$(echo "${diff_content}" | head -n 500)
  fi

  # 2. Build prompt
  local prompt
  prompt=$(build_prompt "${diff_content}")

  # 3. Call AI provider
  local generated_msg=""

  if [[ "${DRY_RUN}" == "1" ]]; then
    print_info "Dry-run mode: Using mock commit message."
    generated_msg=$(mock_response)
  else
    if ! command -v jq &>/dev/null; then
      print_error "'jq' is required but not installed."
      print_info "Install it: brew install jq (macOS) or apt install jq (Linux)"
      exit 0  # Don't block commit, just skip
    fi

    case "${PROVIDER}" in
      claude)
        generated_msg=$(call_claude "${prompt}") || {
          print_warn "Failed to generate message. Commit will proceed with empty message."
          exit 0
        }
        ;;
      openai)
        generated_msg=$(call_openai "${prompt}") || {
          print_warn "Failed to generate message. Commit will proceed with empty message."
          exit 0
        }
        ;;
      ollama)
        generated_msg=$(call_ollama "${prompt}") || {
          print_warn "Failed to generate message. Commit will proceed with empty message."
          exit 0
        }
        ;;
      *)
        print_error "Unknown provider: ${PROVIDER}"
        exit 0
        ;;
    esac
  fi

  if [[ -z "${generated_msg}" ]]; then
    print_warn "AI returned an empty message. Skipping."
    exit 0
  fi

  # 4. Clean up the message (remove surrounding quotes, markdown code blocks)
  generated_msg=$(echo "${generated_msg}" | sed 's/^```[a-z]*$//' | sed 's/^```$//' | sed 's/^"//;s/"$//' | sed '/^$/d')

  # 5. Prefix with ticket number if detected
  if [[ "${TICKET_PREFIX}" == "true" ]]; then
    local ticket
    ticket=$(detect_ticket)

    if [[ -n "${ticket}" ]]; then
      # Only prefix if ticket isn't already in the message
      if ! echo "${generated_msg}" | head -1 | grep -qF "${ticket}"; then
        local first_line
        first_line=$(echo "${generated_msg}" | head -1)
        local rest
        rest=$(echo "${generated_msg}" | tail -n +2)

        generated_msg="${ticket}: ${first_line}"
        if [[ -n "${rest}" ]]; then
          generated_msg="${generated_msg}
${rest}"
        fi

        print_info "Prefixed ticket: ${ticket}"
      fi
    fi
  fi

  # 6. Write the message to the commit message file
  # Preserve any existing comments (lines starting with #)
  local existing_comments
  existing_comments=$(grep '^#' "${COMMIT_MSG_FILE}" 2>/dev/null || true)

  {
    echo "${generated_msg}"
    echo ""
    if [[ -n "${existing_comments}" ]]; then
      echo "${existing_comments}"
    fi
  } > "${COMMIT_MSG_FILE}"

  print_pass "Commit message generated:"
  echo "" >&2
  echo -e "${DIM}$(echo "${generated_msg}" | head -5)${RESET}" >&2
  echo "" >&2
  print_info "Edit the message in your editor if needed."
}

main "$@"
