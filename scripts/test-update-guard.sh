#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

mode="verify-only"
failures=0

# Force non-interactive behavior for test runs.
export CS2_UPDATE_GUARD_SHOW_POPUP=0

usage() {
  cat <<'EOF_USAGE'
Usage: test-update-guard.sh [--verify-only|--help]

Validates update-guard behavior without touching your real baseline file.

Checks:
  1) Approved baseline allows launch checks.
  2) Mismatched baseline blocks launch checks.
EOF_USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

run_checked() {
  local label="$1"
  shift
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/cs2-update-guard.XXXXXX")"

  if "$@" >"$out_file" 2>&1; then
    printf '[OK] %s\n' "$label"
    sed -n '1,40p' "$out_file"
  else
    local status=$?
    printf '[FAIL] %s (exit %s)\n' "$label" "$status" >&2
    sed -n '1,200p' "$out_file" >&2 || true
    failures=$((failures + 1))
  fi

  rm -f "$out_file"
}

expect_blocked() {
  local label="$1"
  shift
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/cs2-update-guard.XXXXXX")"

  set +e
  "$@" >"$out_file" 2>&1
  local status=$?
  set -e

  if [[ "$status" -ne 40 ]]; then
    printf '[FAIL] %s (expected exit 40, got %s)\n' "$label" "$status" >&2
    sed -n '1,200p' "$out_file" >&2 || true
    failures=$((failures + 1))
  else
    printf '[OK] %s\n' "$label"
    sed -n '1,40p' "$out_file"
  fi

  rm -f "$out_file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only)
      mode="verify-only"
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

printf 'Update-guard tests (%s)\n' "$mode"
printf 'Repo root: %s\n' "$repo_root"

run_checked "bash -n scripts/update-guard.sh" bash -n "$repo_root/scripts/update-guard.sh"
run_checked "scripts/update-guard.sh --help" bash "$repo_root/scripts/update-guard.sh" --help

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/cs2-guard-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

baseline_file="$tmp_root/approved-builds.env"
state_dir="$tmp_root/state"
report_file="$tmp_root/report.txt"
fixture_prefix="$tmp_root/prefix"
fixture_steam_root="$fixture_prefix/drive_c/Program Files (x86)/Steam"
fixture_manifest_dir="$fixture_steam_root/package"
fixture_steamapps_dir="$fixture_steam_root/steamapps"
fixture_bin_dir="$tmp_root/runtime-bin"
fixture_wine="$fixture_bin_dir/wine"

mkdir -p "$fixture_manifest_dir" "$fixture_steamapps_dir" "$fixture_bin_dir" "$state_dir"

cat >"$fixture_manifest_dir/steam_client_win64.manifest" <<'EOF_MANIFEST'
"manifest"
{
  "version"    "1773426488"
}
EOF_MANIFEST

cat >"$fixture_steamapps_dir/appmanifest_730.acf" <<'EOF_ACF'
"AppState"
{
  "appid"      "730"
  "buildid"    "22627914"
}
EOF_ACF

cat >"$fixture_wine" <<'EOF_WINE'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "wine-11.0-8709-g34d9442f225"
  exit 0
fi
echo "unsupported fake wine invocation: $*" >&2
exit 1
EOF_WINE
chmod +x "$fixture_wine"

common_env=(
  "CS2_UPDATE_GUARD_BASELINE_FILE=$baseline_file"
  "CS2_UPDATE_GUARD_STATE_DIR=$state_dir"
  "CS2_UPDATE_GUARD_REPORT_FILE=$report_file"
  "CS2_UPDATE_GUARD_SHOW_POPUP=0"
  "CS2_UPDATE_GUARD_RUN_QUICK_CHECKS=0"
  "CS2_MAC_PREFIX=$fixture_prefix"
  "CS2_MAC_ROOT=$tmp_root/project-root"
  "WINE_BIN=$fixture_wine"
)

run_checked "approve-current writes temp baseline" \
  env "${common_env[@]}" bash "$repo_root/scripts/update-guard.sh" --approve-current

run_checked "check passes with approved baseline" \
  env "${common_env[@]}" bash "$repo_root/scripts/update-guard.sh" --check

# Force a version mismatch and confirm launch would be blocked.
if [[ -f "$baseline_file" ]]; then
  perl -0pi -e 's/CS2_APPROVED_STEAM_VERSION="[^"]+"/CS2_APPROVED_STEAM_VERSION="0"/' "$baseline_file"
else
  die "expected baseline file missing: $baseline_file"
fi

expect_blocked "check blocks on mismatched baseline" \
  env "${common_env[@]}" bash "$repo_root/scripts/update-guard.sh" --check

if [[ -f "$report_file" ]] && grep -Fq 'BLOCKED' "$report_file"; then
  printf '[OK] report captures blocked decision\n'
else
  printf '[FAIL] report missing blocked decision\n' >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
  printf '\nUpdate-guard tests failed: %d\n' "$failures" >&2
  exit 1
fi

printf '\nUpdate-guard tests passed.\n'
