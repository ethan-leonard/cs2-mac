#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "$script_dir/.." && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths
default_profile_file="$project_root/config/profile.safe.env"
default_log_dir="$CS2_MAC_LOGS"
default_prefix="$CS2_MAC_PREFIX"
default_appid="730"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: launch-cs2.sh [--profile safe|perf|/path/to/env] [--log-dir DIR] [--appid 730] [--dry-run] [--skip-redist-prime] [--no-fresh-start] [--skip-update-guard]

Launch CS2 through Steam using `steam.exe -applaunch 730` and write a per-run log file.

Options:
  --profile   Load config/profile.safe.env, config/profile.perf.env, or a custom env file path.
  --log-dir   Override the log directory. Defaults to ~/Library/Application Support/CS2-Mac/logs.
  --appid     Steam app ID to launch. Defaults to 730.
  --dry-run   Print the resolved command and environment, then exit.
  --skip-redist-prime  Skip CommonRedist priming before launch.
  --no-fresh-start     Do not pre-clean existing Steam/Wine processes in this prefix.
  --skip-update-guard  Skip update policy guard checks for this run.
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

collect_recent_logs() {
  local marker="$1"
  local -a files=()
  local root

  for root in "$log_dir" "$CS2_MAC_STEAM_ROOT/logs"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' file; do
      files+=("$file")
    done < <(find "$root" -type f -newer "$marker" -print0 2>/dev/null || true)
  done

  printf '%s\n' "${files[@]}"
}

scan_recent_logs_for_service_issue() {
  local marker="$1"
  local -a files=()
  local file
  local service_issue_regex='Steam[[:space:]]+Service[[:space:]]+Error|Steam[[:space:]].*maintenance|maintenance.*Steam'

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    files+=("$file")
  done < <(collect_recent_logs "$marker" | sed '/^$/d' | sort -u)

  for file in "${files[@]}"; do
    if grep -Eiq "$service_issue_regex" "$file"; then
      printf 'steam service/maintenance issue detected in recent logs: %s\n' "$file"
      grep -Ein "$service_issue_regex" "$file" | sed -n '1,4p' || true
      return 0
    fi
  done

  return 1
}

script_name="launch-cs2"
profile_arg="safe"
log_dir="$default_log_dir"
appid="$default_appid"
dry_run=0
skip_redist_prime=0
fresh_start=1
skip_update_guard=0

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
    --skip-redist-prime)
      skip_redist_prime=1
      shift
      ;;
    --no-fresh-start)
      fresh_start=0
      shift
      ;;
    --skip-update-guard)
      skip_update_guard=1
      shift
      ;;
    --)
      shift
      die "unexpected extra arguments after --"
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$appid" =~ ^[0-9]+$ ]] || die "appid must be a positive integer"
profile_file="$(load_profile_env "$profile_arg")"

mkdir -p "$log_dir"
log_file="$log_dir/${script_name}-$(date +%Y%m%d-%H%M%S).log"
touch "$log_file"
exec > >(tee -a "$log_file") 2>&1
launch_marker="$log_dir/${script_name}-$(date +%Y%m%d-%H%M%S).marker"
touch "$launch_marker"

trap 'status=$?; printf "[%s] %s failed at line %s: %s (exit %s)\n" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$script_name" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-unknown}" "$status" >&2' ERR

export WINEPREFIX="${WINEPREFIX:-$default_prefix}"
export CS2_LOG_DIR="${CS2_LOG_DIR:-$log_dir}"
export CS2_APPID="$appid"

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
printf 'skip_update_guard=%q\n' "$skip_update_guard"

cmd=("$wine_bin" "$steam_exe" -applaunch "$appid")
printf 'command:'
for arg in "${cmd[@]}"; do
  printf ' %q' "$arg"
done
printf '\n'

if (( dry_run )); then
  printf 'dry-run: not executing CS2 launch\n'
  exit 0
fi

if pgrep -f 'cs2\.exe[[:space:]]+-steam' >/dev/null 2>&1; then
  die "an existing cs2.exe process is already running; close CS2 first to avoid duplicate instances"
fi

if (( fresh_start == 1 )); then
  printf 'fresh-start: cleaning prefix runtime processes\n'
  "$script_dir/cleanup-runtime.sh" --prefix "$WINEPREFIX" --steam-exe "$steam_exe"
fi

if (( skip_update_guard == 0 )) && [[ "${CS2_SKIP_UPDATE_GUARD:-0}" != "1" ]]; then
  set +e
  "$script_dir/update-guard.sh" --check
  guard_status=$?
  set -e
  if (( guard_status != 0 )); then
    printf 'update-guard blocked launch with exit status %s\n' "$guard_status"
    exit "$guard_status"
  fi
fi

if (( skip_redist_prime == 0 )); then
  printf 'priming CommonRedist run-keys before launch\n'
  WINE_BIN="$wine_bin" WINEPREFIX="$WINEPREFIX" "$script_dir/prime-redists.sh"
fi

set +e
"${cmd[@]}"
status=$?
set -e
if scan_recent_logs_for_service_issue "$launch_marker"; then
  printf 'Steam Service Error / maintenance prompt detected in recent logs; refusing to report a successful launch\n' >&2
  rm -f "$launch_marker"
  exit 1
fi
rm -f "$launch_marker"
if [[ "$status" -eq 42 ]]; then
  printf 'steam updater requested restart (exit 42); treating as successful handoff\n'
  exit 0
fi
exit "$status"
