#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/prefix.sh"

usage() {
  cat <<'USAGE'
Usage: init-prefix.sh [options]

Create or refresh the deterministic CS2 Wine prefix and Steam layout.

Options:
  --prefix PATH       Prefix root to create or reuse.
                      Default: ~/Library/Application Support/CS2-Mac/prefix
  --steam-root PATH   Steam root inside the prefix.
                      Default: <prefix>/drive_c/Program Files (x86)/Steam
  --skip-wineboot     Skip Wine prefix initialization and only create directories.
  --skip-steam-seed   Skip seeding minimal Steam bootstrap files from CrossOver data.
  --verbose           Print the resolved paths before bootstrapping.
  -h, --help          Show this help text.
USAGE
}

prefix_path="$(cs2_prefix_path)"
if [ -n "${CS2_STEAM_ROOT:-}" ]; then
  steam_root_path="$(cs2_steam_root_path)"
  steam_root_explicit=1
else
  steam_root_path="$(cs2_steam_root_from_prefix "$prefix_path")"
  steam_root_explicit=0
fi
skip_wineboot="${CS2_SKIP_WINEBOOT:-0}"
skip_steam_seed="${CS2_SKIP_STEAM_SEED:-0}"
verbose="${CS2_VERBOSE:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      [ $# -ge 2 ] || cs2_die "--prefix requires a path"
      prefix_path="$(cs2_resolve_path "$2")"
      if [ "$steam_root_explicit" = "0" ]; then
        steam_root_path="$(cs2_steam_root_from_prefix "$prefix_path")"
      fi
      shift 2
      ;;
    --prefix=*)
      prefix_path="$(cs2_resolve_path "${1#*=}")"
      if [ "$steam_root_explicit" = "0" ]; then
        steam_root_path="$(cs2_steam_root_from_prefix "$prefix_path")"
      fi
      shift
      ;;
    --steam-root)
      [ $# -ge 2 ] || cs2_die "--steam-root requires a path"
      steam_root_path="$(cs2_resolve_path "$2")"
      steam_root_explicit=1
      shift 2
      ;;
    --steam-root=*)
      steam_root_path="$(cs2_resolve_path "${1#*=}")"
      steam_root_explicit=1
      shift
      ;;
    --skip-wineboot)
      skip_wineboot=1
      shift
      ;;
    --skip-steam-seed)
      skip_steam_seed=1
      shift
      ;;
    --verbose)
      verbose=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      cs2_die "unknown option: $1"
      ;;
  esac
done

if [ "$verbose" = "1" ]; then
  cs2_info "resolved prefix: $prefix_path"
  cs2_info "resolved steam root: $steam_root_path"
fi

export CS2_SKIP_WINEBOOT="$skip_wineboot"
export CS2_SKIP_STEAM_SEED="$skip_steam_seed"

log_dir="$CS2_MAC_LOGS"
cs2_bootstrap_steam_layout "$prefix_path" "$steam_root_path" "$log_dir"

cat <<EOF2
CS2 prefix ready.
Prefix: $prefix_path
Steam root: $steam_root_path
Logs: $log_dir
Next step: launch Steam inside this prefix using the launcher scripts.
EOF2
