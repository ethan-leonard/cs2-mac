#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths

usage() {
  cat <<'USAGE'
Usage: cleanup-runtime.sh [--prefix PATH] [--steam-exe PATH] [--dry-run]

Safely tear down Steam/Wine processes for the configured prefix.

Options:
  --prefix PATH     Override the prefix root to clean. Defaults to CS2_MAC_PREFIX.
  --steam-exe PATH  Override the Steam executable path used for process matching.
  --dry-run         Print the resolved scope and exit without killing anything.
  --help            Show this help.
USAGE
}

prefix_root="$CS2_MAC_PREFIX"
steam_exe=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --prefix)
      [[ $# -ge 2 ]] || cs2_die "--prefix requires a value"
      prefix_root="$2"
      shift 2
      ;;
    --prefix=*)
      prefix_root="${1#*=}"
      shift
      ;;
    --steam-exe)
      [[ $# -ge 2 ]] || cs2_die "--steam-exe requires a value"
      steam_exe="$2"
      shift 2
      ;;
    --steam-exe=*)
      steam_exe="${1#*=}"
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    *)
      cs2_die "unknown argument: $1"
      ;;
  esac
done

if [[ -z "$steam_exe" ]]; then
  steam_exe="$(cs2_resolve_steam_exe_path "$prefix_root" "$STEAM_EXE_REL" || true)"
fi

printf 'CS2 runtime cleanup\n'
printf 'Prefix root: %s\n' "$prefix_root"
printf 'Steam executable: %s\n' "${steam_exe:-<unresolved>}"

if (( dry_run )); then
  printf 'dry-run: not cleaning processes\n'
  exit 0
fi

wineserver_bin="${WINESERVER_BIN:-}"
if [[ -z "$wineserver_bin" ]]; then
  wineserver_bin="$(cs2_resolve_command wineserver || true)"
fi

cs2_cleanup_prefix_runtime "$prefix_root" "$steam_exe" "$wineserver_bin"
