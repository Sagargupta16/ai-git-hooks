#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# AI Git Hooks - Secret Scan Benchmark
# ============================================================================
# Measures the pre-push secret scan against leaky-repo, a public corpus of fake
# credentials with a per-file count of the lines that hold one
# (https://github.com/Plazmaz/leaky-repo, .leaky-meta/secrets.csv).
#
# The corpus files are committed to a throwaway repository and the real hook
# is run on it as a first push, so this exercises the same code path as
# `git push`. With --gitleaks, gitleaks scans the same files for comparison.
#
# Scoring follows leaky-repo's own benchmark.py so the numbers can be compared
# with the tables it publishes:
#   expected  = risk + informative lines listed for the file
#   found     = distinct lines the tool flagged in the file
#   false pos = max(found - expected, 0)
#   finds     = found - false pos, summed over all files
#   covered   = files with at least one flagged line
#
# Usage:
#   ./scripts/benchmark.sh [--gitleaks] [--noise] [path-to-leaky-repo-checkout]
#
#   --gitleaks  also run gitleaks on the same files
#   --noise     also scan the clean projects in NOISE_REPOS and count findings
#
# Without a path it clones leaky-repo at the pinned commit below into a temp
# directory. Needs git, awk and, for --gitleaks, gitleaks and jq on PATH.
# ============================================================================

LEAKY_REPO_URL="https://github.com/Plazmaz/leaky-repo.git"
LEAKY_REPO_COMMIT="2e951359cac53addbee56437da3ffb546e3dfe24"

# Noise check: real projects with no known leaked credential, at pinned tags.
# Every finding here is noise or a deliberate test fixture, and each one would
# block a push, so the count says how often a clean project hits the scan.
NOISE_REPOS=(
  "https://github.com/expressjs/express.git v5.3.0"
  "https://github.com/psf/requests.git v2.34.2"
  "https://github.com/pallets/flask.git 3.1.3"
  "https://github.com/react-hook-form/react-hook-form.git v7.69.0"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../hooks/pre-push/security-scan.sh"
WORK_DIR=""

cleanup() {
  if [[ -n "${WORK_DIR}" ]] && [[ -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

# Read secrets.csv into "<file> <risk> <informative>" lines
read_ground_truth() {
  tr -d '\r' < "$1" | awk -F, '!/^#/ && NF >= 3 { print $1, $2, $3 }'
}

# Score one tool. $1 is the ground truth, $2 a file of distinct "<path>:<line>"
# findings. Prints a summary line, then one row per file.
score() {
  awk -v findings="$2" '
    BEGIN {
      while ((getline f < findings) > 0) {
        sub(/:[0-9]+$/, "", f)
        found[f]++
      }
    }
    {
      name = $1; expected = $2 + $3
      n = (name in found) ? found[name] : 0
      fp = n - expected; if (fp < 0) fp = 0
      total_expected += expected; total_finds += n - fp; total_fp += fp
      files++; if (n > 0) covered++
      rows = rows sprintf("| `%s` | %d/%d | %d |\n", name, n, expected, fp)
    }
    END {
      printf "%d %d %d %d %d\n", covered, files, total_finds, total_expected, total_fp
      printf "%s", rows
    }
  ' "$1"
}

# Run the pre-push hook on the scan repo as a first push and list its findings
run_hook() {
  local scan_dir="$1"
  local sha zero_sha="0000000000000000000000000000000000000000"
  local esc=$'\033'
  sha=$(git -C "${scan_dir}" rev-parse HEAD)

  (cd "${scan_dir}" && echo "refs/heads/main ${sha} refs/heads/main ${zero_sha}" \
    | AI_HOOKS_DRY_RUN=1 bash "${HOOK}" 2>&1 || true) \
    | sed "s/${esc}\[[0-9;]*m//g" \
    | sed -n 's/^\[CRITICAL\] Possible .* found in \(.*:[0-9][0-9]*\)$/\1/p' \
    | sort -u
}

# Run gitleaks on the same files and list its findings the same way
run_gitleaks() {
  local scan_dir="$1"
  local report="${WORK_DIR}/gitleaks.json"
  (cd "${scan_dir}" && gitleaks dir . --no-banner --log-level error \
    --report-format json --report-path "${report}" --exit-code 0 >/dev/null)
  jq -r '.[] | "\(.File):\(.StartLine)"' "${report}" \
    | tr '\134' '/' | sed 's#^\./##' | sort -u
}

# Scan each noise repo with the hook (and gitleaks) and print a table of
# finding counts plus every hook finding, so each one can be checked by eye
run_noise() {
  local with_gitleaks="$1"
  local entry url tag name dir hook_out gl_out
  local listing="${WORK_DIR}/noise-findings.txt"
  : > "${listing}"

  echo "### Noise check on clean projects"
  echo ""
  if [[ "${with_gitleaks}" -eq 1 ]]; then
    echo "| Project | Files | ai-git-hooks findings | gitleaks findings |"
    echo "|---------|-------|-----------------------|-------------------|"
  else
    echo "| Project | Files | ai-git-hooks findings |"
    echo "|---------|-------|-----------------------|"
  fi

  for entry in "${NOISE_REPOS[@]}"; do
    url="${entry% *}"
    tag="${entry#* }"
    name="$(basename "${url}" .git)"
    dir="${WORK_DIR}/noise-${name}"
    echo "Cloning ${name} ${tag}..." >&2
    git -c core.autocrlf=false -c advice.detachedHead=false clone --quiet --depth 1 --branch "${tag}" "${url}" "${dir}" 2>/dev/null

    hook_out="${WORK_DIR}/noise-${name}-hook.txt"
    run_hook "${dir}" > "${hook_out}"
    sed "s#^#${name}/#" "${hook_out}" >> "${listing}"

    if [[ "${with_gitleaks}" -eq 1 ]]; then
      gl_out="${WORK_DIR}/noise-${name}-gitleaks.txt"
      run_gitleaks "${dir}" > "${gl_out}"
      echo "| ${name} ${tag} | $(git -C "${dir}" ls-files | wc -l | tr -d ' ') | $(grep -c . "${hook_out}" || true) | $(grep -c . "${gl_out}" || true) |"
    else
      echo "| ${name} ${tag} | $(git -C "${dir}" ls-files | wc -l | tr -d ' ') | $(grep -c . "${hook_out}" || true) |"
    fi
  done
  echo ""

  if [[ -s "${listing}" ]]; then
    echo "ai-git-hooks findings on these projects:"
    echo ""
    # shellcheck disable=SC2016  # the backticks are Markdown, not a command
    sed 's/^/- `/; s/$/`/' "${listing}"
    echo ""
  fi
}

print_tool() {
  local title="$1" scored="$2"
  local covered files finds expected fp
  read -r covered files finds expected fp <<< "$(head -1 "${scored}")"
  echo "### ${title}"
  echo ""
  echo "- Files covered: ${covered}/${files} ($(awk -v a="${covered}" -v b="${files}" 'BEGIN { printf "%.1f", a * 100 / b }')%)"
  echo "- Lines found: ${finds}/${expected} ($(awk -v a="${finds}" -v b="${expected}" 'BEGIN { printf "%.1f", a * 100 / b }')%)"
  echo "- False positives: ${fp}"
  echo ""
}

main() {
  local with_gitleaks=0 with_noise=0 corpus=""
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --gitleaks) with_gitleaks=1 ;;
      --noise) with_noise=1 ;;
      -h|--help) sed -n '4,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) corpus="${arg}" ;;
    esac
  done

  if [[ "${with_gitleaks}" -eq 1 ]] && ! command -v gitleaks &>/dev/null; then
    echo "--gitleaks given but gitleaks is not on PATH." >&2
    exit 1
  fi

  WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'ai-hooks-bench')
  trap cleanup EXIT

  if [[ -z "${corpus}" ]]; then
    corpus="${WORK_DIR}/leaky-repo"
    echo "Cloning leaky-repo at ${LEAKY_REPO_COMMIT:0:7}..." >&2
    git -c core.autocrlf=false clone --quiet "${LEAKY_REPO_URL}" "${corpus}"
    git -C "${corpus}" -c core.autocrlf=false -c advice.detachedHead=false checkout --quiet "${LEAKY_REPO_COMMIT}"
  fi

  local truth="${WORK_DIR}/truth.txt"
  read_ground_truth "${corpus}/.leaky-meta/secrets.csv" > "${truth}"

  # Only the files with ground truth go into the scan repo, so a finding in
  # the corpus README or LICENSE cannot count either way.
  local scan_dir="${WORK_DIR}/scan"
  mkdir -p "${scan_dir}"
  git -C "${scan_dir}" init --quiet
  git -C "${scan_dir}" config core.autocrlf false
  local name _risk _info
  while read -r name _risk _info; do
    mkdir -p "${scan_dir}/$(dirname "${name}")"
    cp "${corpus}/${name}" "${scan_dir}/${name}"
  done < "${truth}"
  git -C "${scan_dir}" add -A
  git -C "${scan_dir}" -c user.email=bench@example.com -c user.name=bench \
    commit --quiet --no-verify -m "leaky-repo corpus"

  local hook_findings="${WORK_DIR}/hook.txt" hook_scored="${WORK_DIR}/hook-scored.txt"
  run_hook "${scan_dir}" > "${hook_findings}"
  score "${truth}" "${hook_findings}" > "${hook_scored}"

  local gl_findings="${WORK_DIR}/gitleaks.txt" gl_scored="${WORK_DIR}/gitleaks-scored.txt"
  if [[ "${with_gitleaks}" -eq 1 ]]; then
    run_gitleaks "${scan_dir}" > "${gl_findings}"
    score "${truth}" "${gl_findings}" > "${gl_scored}"
  fi

  echo "## Secret scan benchmark"
  echo ""
  echo "Corpus: [leaky-repo](${LEAKY_REPO_URL%.git}) at \`${LEAKY_REPO_COMMIT:0:7}\`, $(wc -l < "${truth}" | tr -d ' ') files."
  echo "Scored with leaky-repo's benchmark.py method (see the header of \`scripts/benchmark.sh\`)."
  echo ""
  print_tool "ai-git-hooks pre-push" "${hook_scored}"
  if [[ "${with_gitleaks}" -eq 1 ]]; then
    # A source build reports no version, so GITLEAKS_VERSION can supply it
    local gl_version
    gl_version="${GITLEAKS_VERSION:-$(gitleaks version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)}"
    print_tool "gitleaks ${gl_version} (default rules)" "${gl_scored}"
  fi

  if [[ "${with_noise}" -eq 1 ]]; then
    run_noise "${with_gitleaks}"
  fi

  echo "### Per file"
  echo ""
  if [[ "${with_gitleaks}" -eq 1 ]]; then
    echo "| File | ai-git-hooks found/expected | false pos | gitleaks found/expected | false pos |"
    echo "|------|-----------------------------|-----------|-------------------------|-----------|"
    paste -d'|' <(tail -n +2 "${hook_scored}" | sed 's/ *|$//') \
      <(tail -n +2 "${gl_scored}" | cut -d'|' -f3- ) \
      | sed 's/||/|/'
  else
    echo "| File | found/expected | false pos |"
    echo "|------|----------------|-----------|"
    tail -n +2 "${hook_scored}"
  fi
}

main "$@"
