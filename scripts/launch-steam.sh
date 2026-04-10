#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "$script_dir/.." && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths
default_profile_file="$project_root/config/profile.safe.env"
default_log_dir="$CS2_MAC_LOGS"
default_prefix="$CS2_MAC_PREFIX"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: launch-steam.sh [--profile safe|perf|/path/to/env] [--log-dir DIR] [--appid 730] [--dry-run] [--no-fresh-start] [--] [steam-args...]

Launch Steam from the configured Wine/GPTK prefix and write a per-run log file.

Options:
  --profile   Load config/profile.safe.env, config/profile.perf.env, or a custom env file path.
  --log-dir   Override the log directory. Defaults to ~/Library/Application Support/CS2-Mac/logs.
  --appid     Steam app ID to launch with `-applaunch`. Omit to open Steam normally.
  --dry-run   Print the resolved command and environment, then exit.
  --no-fresh-start  Do not pre-clean existing Steam/Wine processes in this prefix.
  --help      Show this help.
USAGE
}

load_profile_env() {
  local profile_arg="${1:-safe}"
  local profile_file

  case "$profile_arg" in
    safe)
      profile_file="$default_profile_file"
      ;;
    perf)
      profile_file="$project_root/config/profile.perf.env"
      ;;
    /*|.*|*/*)
      profile_file="$profile_arg"
      ;;
    *)
      die "unknown profile '$profile_arg' (use safe, perf, or a file path)"
      ;;
  esac

  [[ -r "$profile_file" ]] || die "profile file is not readable: $profile_file"

  set -a
  # shellcheck disable=SC1090
  source "$profile_file"
  set +a

  printf '%s\n' "$profile_file"
}

script_name="launch-steam"
profile_arg="safe"
log_dir="$default_log_dir"
appid=""
dry_run=0
fresh_start=1
steam_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value"
      profile_arg="$2"
      shift 2
      ;;
    --profile=*)
      profile_arg="${1#*=}"
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
    --appid)
      [[ $# -ge 2 ]] || die "--appid requires a value"
      appid="$2"
      shift 2
      ;;
    --appid=*)
      appid="${1#*=}"
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --no-fresh-start)
      fresh_start=0
      shift
      ;;
    --)
      shift
      steam_args+=("$@")
      break
      ;;
    *)
      steam_args+=("$1")
      shift
      ;;
  esac
done

profile_file="$(load_profile_env "$profile_arg")"

mkdir -p "$log_dir"
log_file="$log_dir/${script_name}-$(date +%Y%m%d-%H%M%S).log"
touch "$log_file"
exec > >(tee -a "$log_file") 2>&1

trap 'status=$?; printf "[%s] %s failed at line %s: %s (exit %s)\n" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$script_name" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-unknown}" "$status" >&2' ERR

export WINEPREFIX="${WINEPREFIX:-$default_prefix}"
export CS2_LOG_DIR="${CS2_LOG_DIR:-$log_dir}"

wine_bin="${WINE_BIN:-}"
if [[ -n "$wine_bin" ]]; then
  [[ -x "$wine_bin" ]] || die "WINE_BIN is set but not executable: $wine_bin"
elif ! wine_bin="$(cs2_resolve_command wine64 wine)"; then
  die "could not find wine64 or wine on PATH; set WINE_BIN explicitly"
fi

cs2_maybe_set_cx_root_from_wine_bin "$wine_bin"

if [[ -n "${STEAM_EXE:-}" ]]; then
  steam_exe="$STEAM_EXE"
else
  steam_exe="$(cs2_resolve_steam_exe_path "$WINEPREFIX" "$STEAM_EXE_REL" || true)"
fi

if [[ ! -f "$steam_exe" ]]; then
  if (( dry_run )); then
    cs2_warn "Steam.exe not found yet: $steam_exe"
  else
    die "Steam.exe not found: $steam_exe (run scripts/init-prefix.sh first)"
  fi
fi

printf '[%s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$script_name"
printf 'profile_file=%q\n' "$profile_file"
printf 'log_file=%q\n' "$log_file"
printf 'WINEPREFIX=%q\n' "$WINEPREFIX"
printf 'STEAM_EXE=%q\n' "$steam_exe"
printf 'WINE_BIN=%q\n' "$wine_bin"
printf 'appid=%q\n' "$appid"
printf 'fresh_start=%q\n' "$fresh_start"

cmd=("$wine_bin" "$steam_exe")
if [[ -n "$appid" ]]; then
  [[ "$appid" =~ ^[0-9]+$ ]] || die "appid must be a positive integer"
  cmd+=(-applaunch "$appid")
fi
if ((${#steam_args[@]} > 0)); then
  cmd+=("${steam_args[@]}")
fi

printf 'command:'
for arg in "${cmd[@]}"; do
  printf ' %q' "$arg"
done
printf '\n'

if (( dry_run )); then
  printf 'dry-run: not executing Steam\n'
  exit 0
fi

if (( fresh_start == 1 )); then
  printf 'fresh-start: cleaning prefix runtime processes\n'
  "$script_dir/cleanup-runtime.sh" --prefix "$WINEPREFIX" --steam-exe "$steam_exe"
fi

set +e
"${cmd[@]}"
status=$?
set -e
if [[ "$status" -eq 42 ]]; then
  printf 'steam updater requested restart (exit 42); treating as successful handoff\n'
  exit 0
fi
exit "$status"
