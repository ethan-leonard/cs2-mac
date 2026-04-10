#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths

usage() {
  cat <<'EOF'
Usage: collect-logs.sh [--output-dir DIR]

Packages the latest logs plus a filtered environment snapshot into a
timestamped .tar.gz archive.

Environment overrides:
  CS2_MAC_ROOT          Base support directory
  CS2_MAC_PREFIX        Wine prefix root
  CS2_MAC_LOGS          Log root directory
  CS2_HOST_STEAM_ROOT   Native Steam library root
  CROSSOVER_STEAM_BOTTLE Legacy CrossOver bottle root

EOF
}

output_dir=""

while [ "${1:-}" != "" ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --output-dir)
      shift
      if [ "${1:-}" = "" ]; then
        printf 'collect-logs.sh: --output-dir requires a value\n' >&2
        exit 2
      fi
      output_dir="$1"
      ;;
    *)
      printf 'collect-logs.sh: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

project_root="$CS2_MAC_ROOT"
prefix_root="$CS2_MAC_PREFIX"
host_steam_root="${CS2_HOST_STEAM_ROOT:-$HOME/Library/Application Support/Steam}"
cross_steam_root="$CS2_CROSSOVER_STEAM_ROOT"

if [ -z "$output_dir" ]; then
  output_dir="$CS2_MAC_ROOT/bundles"
fi

timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
bundle_name="cs2-mac-logs-$timestamp"
archive_path="$output_dir/$bundle_name.tar.gz"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/cs2-mac-logs.XXXXXX")"
bundle_root="$tmp_root/$bundle_name"
mkdir -p "$bundle_root"/{logs,state}
mkdir -p "$output_dir"

copy_if_exists() {
  local source_path="$1"
  local destination_path="$2"
  if [ -e "$source_path" ]; then
    mkdir -p "$(dirname "$destination_path")"
    cp -p "$source_path" "$destination_path"
  fi
}

snapshot_command() {
  local output_path="$1"
  shift
  (
    "$@"
  ) >"$output_path" 2>&1 || true
}

write_env_snapshot() {
  local output_path="$1"
  {
    echo "PWD=$PWD"
    echo "USER=${USER:-}"
    echo "HOME=${HOME:-}"
    echo "SHELL=${SHELL:-}"
    echo "PATH=${PATH:-}"
    echo "TMPDIR=${TMPDIR:-}"
    echo "CS2_MAC_ROOT=$project_root"
    echo "CS2_MAC_PREFIX=$prefix_root"
    echo "CS2_MAC_LOGS=$CS2_MAC_LOGS"
    echo "CS2_HOST_STEAM_ROOT=${CS2_HOST_STEAM_ROOT:-$host_steam_root}"
    echo "CROSSOVER_STEAM_BOTTLE=$CROSSOVER_STEAM_BOTTLE"
    echo "CS2_CROSSOVER_STEAM_ROOT=$cross_steam_root"
    echo "WINE_BIN=${WINE_BIN:-}"
    echo "WINESERVER_BIN=${WINESERVER_BIN:-}"
    echo
    env | LC_ALL=C sort | grep -E '^(CS2_|WINE|WINESERVER|STEAM|HOME=|PATH=|SHELL=|USER=|LANG=|LC_)' || true
  } >"$output_path"
}

copy_latest_logs() {
  local limit="${1:-25}"
  local listing_file="$tmp_root/latest-logs.tsv"
  : >"$listing_file"

  add_source() {
    local label="$1"
    local root="$2"
    if [ -d "$root" ]; then
      find "$root" -type f -print0 2>/dev/null | while IFS= read -r -d '' file; do
        local mtime
        mtime="$(stat -f '%m' "$file" 2>/dev/null || echo 0)"
        printf '%s\t%s\t%s\t%s\n' "$mtime" "$label" "$root" "$file" >>"$listing_file"
      done
    fi
  }

  add_source "project" "$CS2_MAC_LOGS"
  add_source "host-steam" "$host_steam_root/logs"
  add_source "prefix-steam" "$prefix_root/drive_c/Program Files (x86)/Steam/logs"
  add_source "crossover-steam" "$cross_steam_root/logs"

  if [ ! -s "$listing_file" ]; then
    return
  fi

  sort -rn -k1,1 "$listing_file" | awk -v limit="$limit" 'NR <= limit' | while IFS=$'\t' read -r _ label root file; do
    local rel dest
    case "$file" in
      "$root"/*)
        rel="${file#"$root"/}"
        ;;
      *)
        rel="$(basename "$file")"
        ;;
    esac
    dest="$bundle_root/logs/$label/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -p "$file" "$dest"
  done
}

run_doctor() {
  local output_path="$bundle_root/state/doctor.txt"
  local status_path="$bundle_root/state/doctor.exitcode"
  set +e
  "$repo_root/scripts/doctor.sh" >"$output_path" 2>&1
  local status=$?
  set -e
  printf '%s\n' "$status" >"$status_path"
}

main() {
  if [ ! -d "$repo_root" ]; then
    printf 'collect-logs.sh: repo root not found: %s\n' "$repo_root" >&2
    exit 1
  fi

  write_env_snapshot "$bundle_root/state/env.txt"
  snapshot_command "$bundle_root/state/uname.txt" uname -a
  snapshot_command "$bundle_root/state/sw_vers.txt" sw_vers
  snapshot_command "$bundle_root/state/df.txt" df -h "$HOME" "$project_root" "$prefix_root"
  snapshot_command "$bundle_root/state/git-status.txt" git -C "$repo_root" status --short
  snapshot_command "$bundle_root/state/git-branch.txt" git -C "$repo_root" branch --show-current
  snapshot_command "$bundle_root/state/system-display.txt" system_profiler SPDisplaysDataType

  copy_if_exists "$repo_root/README.md" "$bundle_root/state/README.md"
  copy_if_exists "$repo_root/MIGRATION.md" "$bundle_root/state/MIGRATION.md"
  copy_if_exists "$repo_root/RUNBOOK.md" "$bundle_root/state/RUNBOOK.md"
  copy_if_exists "$prefix_root/drive_c/Program Files (x86)/Steam/steamapps/appmanifest_730.acf" \
    "$bundle_root/state/prefix-appmanifest_730.acf"
  copy_if_exists "$prefix_root/drive_c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf" \
    "$bundle_root/state/prefix-libraryfolders.vdf"
  copy_if_exists "$host_steam_root/steamapps/appmanifest_730.acf" \
    "$bundle_root/state/host-appmanifest_730.acf"
  copy_if_exists "$host_steam_root/steamapps/libraryfolders.vdf" \
    "$bundle_root/state/host-libraryfolders.vdf"
  copy_if_exists "$cross_steam_root/steamapps/appmanifest_730.acf" \
    "$bundle_root/state/crossover-appmanifest_730.acf"
  copy_if_exists "$cross_steam_root/config/config.vdf" \
    "$bundle_root/state/crossover-config.vdf"
  copy_if_exists "$cross_steam_root/config/loginusers.vdf" \
    "$bundle_root/state/crossover-loginusers.vdf"

  run_doctor
  copy_latest_logs 25

  tar -czf "$archive_path" -C "$tmp_root" "$bundle_name"
  rm -rf "$tmp_root"

  printf '%s\n' "$archive_path"
}

main "$@"
