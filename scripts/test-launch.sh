#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths
mode="verify-only"
profile="safe"
appid="730"
log_dir="$CS2_MAC_LOGS"
failures=0

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: test-launch.sh [options]

Validates the Steam and CS2 launch entrypoints.

Default mode is --verify-only. In that mode the harness only runs dry-run
checks and never launches Steam or CS2.

Options:
  --verify-only          Read-only checks and dry-run planning only.
  --apply                Run the CS2 launch script for real.
  --profile NAME|PATH    Forward a launch profile to the launch scripts.
  --appid ID             Steam app id to launch. Defaults to 730.
  --log-dir DIR          Override the log directory used by the launch scripts.
  -h, --help             Show this help text.

EOF
}

run_checked() {
  local label="$1"
  shift
  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/cs2-launch.XXXXXX")"

  if "$@" >"$output_file" 2>&1; then
    printf '[OK] %s\n' "$label"
    if [[ -s "$output_file" ]]; then
      sed -n '1,60p' "$output_file"
    fi
  else
    local status=$?
    printf '[FAIL] %s (exit %s)\n' "$label" "$status" >&2
    sed -n '1,200p' "$output_file" >&2 || true
    failures=$((failures + 1))
  fi

  rm -f "$output_file"
}

runtime_available() {
  if [[ -n "${WINE_BIN:-}" && -x "${WINE_BIN:-}" ]]; then
    return 0
  fi
  command -v wine64 >/dev/null 2>&1 || command -v wine >/dev/null 2>&1
}

check_paths() {
  local rel_path="$1"
  [[ -f "$repo_root/$rel_path" ]] || die "missing file: $rel_path"
  [[ -x "$repo_root/$rel_path" ]] || die "not executable: $rel_path"
}

verify_only_checks() {
  if ! runtime_available; then
    printf '[WARN] skipping launch dry-runs because wine/wine64 is not installed yet\n'
    return 0
  fi

  run_checked "launch-steam dry-run" \
    env CS2_SKIP_UPDATE_GUARD=1 bash "$repo_root/scripts/launch-steam.sh" \
    --dry-run \
    --profile "$profile" \
    --appid "$appid" \
    --log-dir "$log_dir"

  run_checked "launch-cs2 dry-run" \
    env CS2_SKIP_UPDATE_GUARD=1 bash "$repo_root/scripts/launch-cs2.sh" \
    --dry-run \
    --profile "$profile" \
    --appid "$appid" \
    --log-dir "$log_dir"
}

apply_checks() {
  verify_only_checks

  run_checked "launch-cs2 apply" \
    env CS2_SKIP_UPDATE_GUARD=1 bash "$repo_root/scripts/launch-cs2.sh" \
    --profile "$profile" \
    --appid "$appid" \
    --log-dir "$log_dir"
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
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value"
      profile="$2"
      shift 2
      ;;
    --profile=*)
      profile="${1#*=}"
      shift
      ;;
    --appid)
      [[ $# -ge 2 ]] || die "--appid requires a value"
      appid="$2"
      shift 2
      ;;
    --appid=*)
      appid="${1#*=}"
      shift
      ;;
    --log-dir)
      [[ $# -ge 2 ]] || die "--log-dir requires a value"
      log_dir="$2"
      shift 2
      ;;
    --log-dir=*)
      log_dir="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

printf 'CS2 launch checks (%s)\n' "$mode"
printf 'Profile: %s\n' "$profile"
printf 'App ID: %s\n' "$appid"
printf 'Log dir: %s\n' "$log_dir"

for rel_path in scripts/launch-steam.sh scripts/launch-cs2.sh; do
  check_paths "$rel_path"
  run_checked "bash -n $rel_path" bash -n "$repo_root/$rel_path"
  run_checked "$rel_path --help" bash "$repo_root/$rel_path" --help
done

if [[ "$mode" == "verify-only" ]]; then
  verify_only_checks
else
  apply_checks
fi

if [[ "$failures" -gt 0 ]]; then
  printf '\nLaunch checks failed: %d\n' "$failures" >&2
  exit 1
fi

printf '\nLaunch checks passed.\n'
