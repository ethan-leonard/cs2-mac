#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths
mode="verify-only"
failures=0

owned_scripts=(
  "scripts/test-smoke.sh"
  "scripts/test-migration.sh"
  "scripts/test-launch.sh"
  "scripts/test-update-guard.sh"
  "scripts/cleanup-runtime.sh"
)

support_scripts=(
  "scripts/check-prereqs.sh"
  "scripts/install-runtime.sh"
  "scripts/verify-runtime.sh"
  "scripts/init-prefix.sh"
  "scripts/build-cs2-app.sh"
  "scripts/doctor.sh"
  "scripts/launch-cs2.sh"
  "scripts/launch-steam.sh"
  "scripts/update-guard.sh"
  "scripts/adopt-existing-cs2.sh"
  "scripts/migrate-steam-session.sh"
)

required_configs=(
  "config/paths.env"
  "config/versions.lock"
  "config/profile.safe.env"
  "config/profile.perf.env"
  "config/update-policy.env"
)

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: test-smoke.sh [--verify-only|--apply]

Runs lightweight repo-level acceptance checks.

Default mode is --verify-only, which only reads files and validates script
syntax/help output. Use --apply to add live, non-destructive environment
checks such as doctor output and launch dry-runs.

EOF
}

require_file() {
  local rel_path="$1"
  local abs_path="$repo_root/$rel_path"
  [[ -f "$abs_path" ]] || die "missing file: $rel_path"
}

require_executable() {
  local rel_path="$1"
  local abs_path="$repo_root/$rel_path"
  [[ -x "$abs_path" ]] || die "not executable: $rel_path"
}

run_checked() {
  local label="$1"
  shift
  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/cs2-smoke.XXXXXX")"

  if "$@" >"$output_file" 2>&1; then
    printf '[OK] %s\n' "$label"
    if [[ -s "$output_file" ]]; then
      sed -n '1,40p' "$output_file"
    fi
  else
    local status=$?
    printf '[FAIL] %s (exit %s)\n' "$label" "$status" >&2
    sed -n '1,200p' "$output_file" >&2 || true
    failures=$((failures + 1))
  fi

  rm -f "$output_file"
}

check_help() {
  local rel_path="$1"
  run_checked "$rel_path --help" bash "$repo_root/$rel_path" --help
}

check_bash_syntax() {
  local rel_path="$1"
  run_checked "bash -n $rel_path" bash -n "$repo_root/$rel_path"
}

check_readme_mentions() {
  local needle="$1"
  if grep -Fq "$needle" "$repo_root/README.md"; then
    printf '[OK] README mentions %s\n' "$needle"
  else
    printf '[FAIL] README is missing %s\n' "$needle" >&2
    failures=$((failures + 1))
  fi
}

live_checks() {
  run_checked "doctor" bash "$repo_root/scripts/doctor.sh"
  run_checked "launch-cs2 dry-run" bash "$repo_root/scripts/launch-cs2.sh" --dry-run
  run_checked "launch-steam dry-run" bash "$repo_root/scripts/launch-steam.sh" --dry-run
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only)
      mode="verify-only"
      shift
      ;;
    --apply)
      mode="apply"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

printf 'CS2 smoke checks (%s)\n' "$mode"
printf 'Repo root: %s\n' "$repo_root"

require_file "README.md"
for rel_path in "${owned_scripts[@]}"; do
  require_file "$rel_path"
  require_executable "$rel_path"
  check_bash_syntax "$rel_path"
  check_help "$rel_path"
done

for rel_path in "${support_scripts[@]}"; do
  require_file "$rel_path"
  require_executable "$rel_path"
  check_bash_syntax "$rel_path"
done

for rel_path in "${required_configs[@]}"; do
  require_file "$rel_path"
done

check_readme_mentions "./scripts/test-smoke.sh"
check_readme_mentions "./scripts/test-migration.sh"
check_readme_mentions "./scripts/test-launch.sh"
check_readme_mentions "./scripts/test-update-guard.sh"
check_readme_mentions "./scripts/cleanup-runtime.sh"
check_readme_mentions "./scripts/check-prereqs.sh"
check_readme_mentions "./scripts/install-runtime.sh"
check_readme_mentions "./scripts/verify-runtime.sh"
check_readme_mentions "./scripts/init-prefix.sh"
check_readme_mentions "./scripts/build-cs2-app.sh"
check_readme_mentions "./scripts/adopt-existing-cs2.sh"
check_readme_mentions "./scripts/migrate-steam-session.sh"
check_readme_mentions "./scripts/launch-cs2.sh"
check_readme_mentions "./scripts/update-guard.sh"
check_readme_mentions "./scripts/doctor.sh"
check_readme_mentions "./scripts/collect-logs.sh"

if [[ "$mode" == "apply" ]]; then
  live_checks
fi

if [[ "$failures" -gt 0 ]]; then
  printf '\nSmoke checks failed: %d\n' "$failures" >&2
  exit 1
fi

printf '\nSmoke checks passed.\n'
