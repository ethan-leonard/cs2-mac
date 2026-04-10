#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

apply_migration=0
skip_migration_dry_run=0
skip_app_build=0

usage() {
  cat <<'EOF'
Usage: setup.sh [options]

Runs the recommended first-time setup flow without launching Steam or CS2.

Default behavior:
  1) checks prerequisites
  2) installs runtime shims/tooling
  3) verifies runtime binaries
  4) initializes prefix structure
  5) runs migration dry-runs (no file moves)
  6) builds app launchers in /Applications

Options:
  --with-migration-apply   Run migration apply steps after dry-runs.
  --skip-migration-dry-run Skip migration dry-runs.
  --skip-app-build         Do not build /Applications app launchers.
  -h, --help               Show this help text.
EOF
}

run_step() {
  local label="$1"
  shift
  printf '\n== %s ==\n' "$label"
  "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-migration-apply)
      apply_migration=1
      shift
      ;;
    --skip-migration-dry-run)
      skip_migration_dry_run=1
      shift
      ;;
    --skip-app-build)
      skip_app_build=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

run_step "Prerequisites" bash "$script_dir/check-prereqs.sh"
run_step "Install runtime" bash "$script_dir/install-runtime.sh"
run_step "Verify runtime" bash "$script_dir/verify-runtime.sh"
run_step "Initialize prefix" bash "$script_dir/init-prefix.sh"

if [[ "$skip_migration_dry_run" -eq 0 ]]; then
  run_step "CS2 content migration dry-run" bash "$script_dir/adopt-existing-cs2.sh" --dry-run
  run_step "Steam session migration dry-run" bash "$script_dir/migrate-steam-session.sh" --dry-run
fi

if [[ "$apply_migration" -eq 1 ]]; then
  run_step "CS2 content migration apply" bash "$script_dir/adopt-existing-cs2.sh" --apply
  run_step "Steam session migration apply" bash "$script_dir/migrate-steam-session.sh" --apply
fi

if [[ "$skip_app_build" -eq 0 ]]; then
  run_step "Build macOS app launchers" bash "$script_dir/build-apps.sh"
fi

cat <<EOF_SUMMARY

Setup complete.

Repo: $repo_root

Recommended next steps:
  1) Review migration dry-run output.
  2) If needed, apply migrations:
       ./scripts/adopt-existing-cs2.sh --apply
       ./scripts/migrate-steam-session.sh --apply
  3) After validating stability, approve update baseline:
       ./scripts/update-guard.sh --approve-current
  4) Launch from /Applications/CS2.app
EOF_SUMMARY
