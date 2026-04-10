#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths
mode="verify-only"
source_steam_root="$CS2_CROSSOVER_STEAM_ROOT"
target_steam_root="$CS2_MAC_STEAM_ROOT"
backup_root="$CS2_MAC_ROOT/backups"
failures=0

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: test-migration.sh [options]

Validates the CS2 payload and Steam session migration path.

Default mode is --verify-only. In that mode the harness only runs dry-run
checks against the migration scripts and does not move any files.

Options:
  --verify-only          Read-only checks and dry-run planning only.
  --apply                Run the underlying migration scripts with --apply.
  --source-steam-root    Override the legacy CrossOver Steam root.
  --target-steam-root    Override the target Steam root in the new prefix.
  --backup-root          Override the backup root used by the migration scripts.
  -h, --help             Show this help text.

EOF
}

run_checked() {
  local label="$1"
  shift
  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/cs2-migration.XXXXXX")"

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

assert_no_duplicate_payload() {
  local source_payload="$source_steam_root/steamapps/common/Counter-Strike Global Offensive"
  local target_payload="$target_steam_root/steamapps/common/Counter-Strike Global Offensive"

  if [[ -d "$source_payload" && -d "$target_payload" ]]; then
    printf '[FAIL] duplicate CS2 payload found in both source and target roots\n' >&2
    printf '       source: %s\n' "$source_payload" >&2
    printf '       target: %s\n' "$target_payload" >&2
    failures=$((failures + 1))
    return 1
  fi

  printf '[OK] no duplicate CS2 payload across source/target roots\n'
}

check_paths() {
  local rel_path="$1"
  [[ -f "$repo_root/$rel_path" ]] || die "missing file: $rel_path"
  [[ -x "$repo_root/$rel_path" ]] || die "not executable: $rel_path"
}

show_plan() {
  printf 'Source Steam root: %s\n' "$source_steam_root"
  printf 'Target Steam root: %s\n' "$target_steam_root"
  printf 'Backup root: %s\n' "$backup_root"
}

verify_only_checks() {
  run_checked "adopt-existing-cs2 dry-run" \
    bash "$repo_root/scripts/adopt-existing-cs2.sh" \
    --dry-run \
    --source-steam-root "$source_steam_root" \
    --target-steam-root "$target_steam_root" \
    --backup-root "$backup_root"

  run_checked "migrate-steam-session dry-run" \
    bash "$repo_root/scripts/migrate-steam-session.sh" \
    --dry-run \
    --source-steam-root "$source_steam_root" \
    --target-steam-root "$target_steam_root" \
    --backup-root "$backup_root"
}

apply_checks() {
  verify_only_checks

  run_checked "adopt-existing-cs2 apply" \
    bash "$repo_root/scripts/adopt-existing-cs2.sh" \
    --apply \
    --source-steam-root "$source_steam_root" \
    --target-steam-root "$target_steam_root" \
    --backup-root "$backup_root"

  run_checked "migrate-steam-session apply" \
    bash "$repo_root/scripts/migrate-steam-session.sh" \
    --apply \
    --source-steam-root "$source_steam_root" \
    --target-steam-root "$target_steam_root" \
    --backup-root "$backup_root"

  assert_no_duplicate_payload || true
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
    --source-steam-root)
      [[ $# -ge 2 ]] || die "--source-steam-root requires a path"
      source_steam_root="$2"
      shift 2
      ;;
    --target-steam-root)
      [[ $# -ge 2 ]] || die "--target-steam-root requires a path"
      target_steam_root="$2"
      shift 2
      ;;
    --backup-root)
      [[ $# -ge 2 ]] || die "--backup-root requires a path"
      backup_root="$2"
      shift 2
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

printf 'CS2 migration checks (%s)\n' "$mode"
show_plan

for rel_path in scripts/adopt-existing-cs2.sh scripts/migrate-steam-session.sh; do
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
  printf '\nMigration checks failed: %d\n' "$failures" >&2
  exit 1
fi

printf '\nMigration checks passed.\n'
