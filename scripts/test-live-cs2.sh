#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths

script_name="test-live-cs2"
default_attempts=3
attempts="$default_attempts"
timeout_seconds=180
settle_seconds=10
cooldown_seconds=5
profile_arg="safe"
appid="730"
log_dir="$CS2_MAC_LOGS"
dry_run=0
failures=0
wine_bin=""
report_root=""
launch_pid=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

note() {
  printf '%s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage: test-live-cs2.sh [options]

Runs repeated live CS2 launch validation through the normal Steam launch path.
Default behavior is three attempts. Each attempt is launched, observed, and then
cleaned up before the next one starts.

Success requires Steam/game log evidence that AppID 730 reached process creation.
Seeing `cs2.exe` alone is not enough; the script waits for the Steam handoff
log evidence that the launch actually surfaced.
The script only uses the standard launch wrapper and log inspection. It does not
inject input, bypass anti-cheat, or otherwise touch protected game state.

Options:
  --attempts N           Number of launch attempts to run. Defaults to 3.
  --timeout-seconds N    Per-attempt timeout before teardown. Defaults to 180.
  --settle-seconds N     Wait after teardown before final log scan. Defaults to 10.
  --cooldown-seconds N   Wait after teardown before the next attempt. Defaults to 5.
  --profile NAME|PATH    Forward a launch profile to launch-cs2.sh.
  --appid ID             Steam app id to validate. Defaults to 730.
  --log-dir DIR          Override the log directory used by the launch scripts.
  --dry-run              Print the planned work and run a launch dry-run only.
  -h, --help             Show this help text.

EOF
}

require_script() {
  local rel_path="$1"
  local abs_path="$repo_root/$rel_path"
  [[ -f "$abs_path" ]] || die "missing file: $rel_path"
  [[ -x "$abs_path" ]] || die "not executable: $rel_path"
}

require_uint() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$label must be a non-negative integer"
}

require_positive_int() {
  local label="$1"
  local value="$2"
  require_uint "$label" "$value"
  [[ "$value" -gt 0 ]] || die "$label must be greater than zero"
}

resolve_runtime() {
  if [[ -n "${WINE_BIN:-}" ]]; then
    [[ -x "$WINE_BIN" ]] || die "WINE_BIN is set but not executable: $WINE_BIN"
    wine_bin="$WINE_BIN"
  else
    wine_bin="$(cs2_resolve_command wine64 wine || true)"
    [[ -n "$wine_bin" ]] || die "could not find wine64 or wine on PATH; set WINE_BIN explicitly"
  fi

}

check_launch_script() {
  require_script "scripts/launch-cs2.sh"
  require_script "scripts/cleanup-runtime.sh"
  note "Checking launch script syntax and help output"
  bash -n "$repo_root/scripts/launch-cs2.sh"
  bash "$repo_root/scripts/launch-cs2.sh" --help >/dev/null
  bash -n "$repo_root/scripts/cleanup-runtime.sh"
  bash "$repo_root/scripts/cleanup-runtime.sh" --help >/dev/null
}

print_plan() {
  note "CS2 live validation"
  note "Attempts: $attempts"
  note "Timeout per attempt: ${timeout_seconds}s"
  note "Settle delay: ${settle_seconds}s"
  note "Cooldown between attempts: ${cooldown_seconds}s"
  note "Profile: $profile_arg"
  note "App ID: $appid"
  note "Log dir: $log_dir"
  note "Report dir: $report_root"
}

cleanup_launch() {
  local reason="$1"

  if [[ -n "$launch_pid" ]] && kill -0 "$launch_pid" 2>/dev/null; then
    note "Stopping launch wrapper pid $launch_pid (${reason})"
    kill "$launch_pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$launch_pid" 2>/dev/null || true
  fi

  note "Running scoped runtime cleanup for prefix teardown"
  "$repo_root/scripts/cleanup-runtime.sh" --prefix "$CS2_MAC_PREFIX"

  launch_pid=""
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

count_file_lines() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf '0\n'
    return 0
  fi
  wc -l <"$file" | tr -d ' '
}

capture_attempt_offsets() {
  local offset_file="$1"
  local file
  : >"$offset_file"
  for file in \
    "$CS2_MAC_STEAM_ROOT/logs/console_log.txt" \
    "$CS2_MAC_STEAM_ROOT/logs/gameprocess_log.txt" \
    "$CS2_MAC_STEAM_ROOT/logs/service_log.txt"; do
    printf '%s\t%s\n' "$file" "$(count_file_lines "$file")" >>"$offset_file"
  done
}

offset_for_file() {
  local offset_file="$1"
  local file="$2"
  awk -F '\t' -v target="$file" '$1 == target { print $2; found=1; exit } END { if (!found) print 0 }' "$offset_file" 2>/dev/null || printf '0\n'
}

new_content_matches() {
  local file="$1"
  local regex="$2"
  local offset_file="$3"
  local offset
  local start_line

  [[ -f "$file" ]] || return 1
  offset="$(offset_for_file "$offset_file" "$file")"
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  start_line=$((offset + 1))

  tail -n +"$start_line" "$file" | grep -Eiq "$regex"
}

print_new_content_matches() {
  local file="$1"
  local regex="$2"
  local offset_file="$3"
  local limit="${4:-4}"
  local offset
  local start_line

  [[ -f "$file" ]] || return 0
  offset="$(offset_for_file "$offset_file" "$file")"
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  start_line=$((offset + 1))

  tail -n +"$start_line" "$file" | grep -Ein "$regex" | sed -n "1,${limit}p" || true
}

scan_new_crash_dumps() {
  local marker="$1"
  local dumps_dir="$CS2_MAC_STEAM_ROOT/dumps"
  local found=0
  local dump_file

  [[ -d "$dumps_dir" ]] || return 0

  while IFS= read -r -d '' dump_file; do
    [[ -n "$dump_file" ]] || continue
    found=1
    warn "new crash dump detected during attempt: $dump_file"
  done < <(find "$dumps_dir" -type f -newer "$marker" \( -name 'crash_cs2.exe_*' -o -name 'assert_cs2.exe_*' \) -print0 2>/dev/null || true)

  if [[ "$found" -eq 1 ]]; then
    return 1
  fi
  return 0
}

scan_logs_for_service_issue() {
  local marker="$1"
  local offset_file="$2"
  local -a files=()
  local file
  local service_issue_regex='Steam[[:space:]]+Service[[:space:]]+Error|Steam[[:space:]].*maintenance|maintenance.*Steam'

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    files+=("$file")
  done < <(collect_recent_logs "$marker" | sed '/^$/d' | sort -u)

  if [[ "${#files[@]}" -eq 0 ]]; then
    return 1
  fi

  for file in "${files[@]}"; do
    if new_content_matches "$file" "$service_issue_regex" "$offset_file"; then
      warn "Steam Service Error / maintenance prompt detected in recent logs: $file"
      print_new_content_matches "$file" "$service_issue_regex" "$offset_file" 4
      return 0
    fi
  done

  return 1
}

scan_logs_for_success() {
  local marker="$1"
  local offset_file="$2"
  local mode="${3:-}"
  local quiet=0
  local strong_process_regex
  local file
  local strong_hit=0
  local -a files=()

  if [[ "$mode" == "--quiet" ]]; then
    quiet=1
  fi

  strong_process_regex="AppID[[:space:]]*${appid}[[:space:]]+adding PID[^[:cntrl:]]*cs2\\.exe[^\n]*-steam|Game process added[[:space:]]*:[[:space:]]*AppID[[:space:]]*${appid}"

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    files+=("$file")
  done < <(collect_recent_logs "$marker" | sed '/^$/d' | sort -u)

  if [[ "${#files[@]}" -eq 0 ]]; then
    if (( quiet == 0 )); then
      note "No recent log files were updated during this attempt"
    fi
    return 1
  fi

  if (( quiet == 0 )); then
    note "Recent log files:"
    for file in "${files[@]}"; do
      note "  $file"
    done
  fi

  for file in "${files[@]}"; do
    if new_content_matches "$file" "$strong_process_regex" "$offset_file"; then
      strong_hit=1
      if (( quiet == 0 )); then
        note "  Strong game-process evidence: $file"
        print_new_content_matches "$file" "$strong_process_regex" "$offset_file" 4
      fi
    fi
  done

  if [[ "$strong_hit" -eq 1 ]]; then
    return 0
  fi

  if (( quiet == 0 )); then
    warn "No strong AppID $appid game-process evidence found in recent logs"
  fi
  return 1
}

run_launch_attempt() {
  local attempt_no="$1"
  local attempt_dir="$report_root/attempt-$(printf '%02d' "$attempt_no")"
  local marker="$attempt_dir/marker"
  local offset_file="$attempt_dir/log-offsets.tsv"
  local capture_log="$attempt_dir/launch-cs2.stdout.log"
  local launch_status=0
  local timed_out=0
  local success_observed=0
  local process_observed=0
  local service_issue_observed=0
  local cleaned_up=0
  local deadline
  local pid

  mkdir -p "$attempt_dir"
  capture_attempt_offsets "$offset_file"
  : >"$marker"
  sleep 1

  note ""
  note "Attempt $attempt_no/$attempts"
  note "  Capture log: $capture_log"
  note "  Marker: $marker"

  set +e
  bash "$repo_root/scripts/launch-cs2.sh" \
    --profile "$profile_arg" \
    --appid "$appid" \
    --log-dir "$log_dir" >"$capture_log" 2>&1 &
  launch_pid=$!
  set -e

  deadline=$((SECONDS + timeout_seconds))
  while kill -0 "$launch_pid" 2>/dev/null; do
    if scan_logs_for_service_issue "$marker" "$offset_file"; then
      service_issue_observed=1
      break
    fi
    if pgrep -f 'cs2\.exe[[:space:]]+-steam' >/dev/null 2>&1; then
      process_observed=1
    fi
    if scan_logs_for_success "$marker" "$offset_file" --quiet; then
      success_observed=1
      note "Detected AppID $appid process handoff evidence; ending attempt early"
      break
    fi
    if (( SECONDS >= deadline )); then
      timed_out=1
      break
    fi
    sleep 2
  done

  pid="$launch_pid"

  if [[ "$service_issue_observed" -eq 1 ]]; then
    warn "Attempt $attempt_no hit a Steam Service Error / maintenance prompt; the launch did not reach the game cleanly"
    cleanup_launch "service issue"
    cleaned_up=1
    set +e
    wait "$pid" >/dev/null 2>&1 || true
    set -e
    launch_status=1
  elif [[ "$success_observed" -eq 1 ]]; then
    cleanup_launch "success evidence observed"
    cleaned_up=1
    set +e
    wait "$pid" >/dev/null 2>&1
    set -e
    launch_status=0
  elif [[ "$timed_out" -eq 1 ]]; then
    warn "Attempt $attempt_no timed out after ${timeout_seconds}s"
    cleanup_launch "timeout"
    cleaned_up=1
    set +e
    wait "$pid"
    launch_status=$?
    set -e
    launch_status=124
  else
    set +e
    wait "$pid"
    launch_status=$?
    set -e
  fi

  note "Launch wrapper exit status: $launch_status"
  sleep "$settle_seconds"

  if [[ "$service_issue_observed" -eq 1 ]]; then
    if [[ "$cleaned_up" -eq 0 ]]; then
      cleanup_launch "post-attempt teardown"
    fi
    return 1
  fi

  if ! scan_logs_for_success "$marker" "$offset_file"; then
    if [[ "$process_observed" -eq 1 ]]; then
      warn "Attempt $attempt_no looks stuck: cs2.exe appeared, but Steam never emitted strong AppID $appid handoff evidence. This is consistent with a launched-but-not-surfacing failure."
    else
      warn "No live cs2.exe process was observed during attempt $attempt_no"
    fi
    if [[ "$cleaned_up" -eq 0 ]]; then
      cleanup_launch "post-attempt teardown"
    fi
    return 1
  fi

  if ! scan_new_crash_dumps "$marker"; then
    if [[ "$cleaned_up" -eq 0 ]]; then
      cleanup_launch "post-attempt teardown"
    fi
    return 1
  fi

  note "Attempt $attempt_no passed"

  if [[ "$cleaned_up" -eq 0 ]]; then
    cleanup_launch "post-attempt teardown"
  fi
  sleep "$cooldown_seconds"
  return 0
}

dry_run_mode() {
  note "Dry-run mode"
  if command -v wine64 >/dev/null 2>&1 || command -v wine >/dev/null 2>&1; then
    note "Running launch-cs2 dry-run for command sanity"
    bash "$repo_root/scripts/launch-cs2.sh" \
      --dry-run \
      --profile "$profile_arg" \
      --appid "$appid" \
      --log-dir "$log_dir"
  else
    warn "wine/wine64 is not installed yet; skipping launch-cs2 dry-run"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --attempts)
      [[ $# -ge 2 ]] || die "--attempts requires a value"
      attempts="$2"
      shift 2
      ;;
    --attempts=*)
      attempts="${1#*=}"
      shift
      ;;
    --timeout-seconds)
      [[ $# -ge 2 ]] || die "--timeout-seconds requires a value"
      timeout_seconds="$2"
      shift 2
      ;;
    --timeout-seconds=*)
      timeout_seconds="${1#*=}"
      shift
      ;;
    --settle-seconds)
      [[ $# -ge 2 ]] || die "--settle-seconds requires a value"
      settle_seconds="$2"
      shift 2
      ;;
    --settle-seconds=*)
      settle_seconds="${1#*=}"
      shift
      ;;
    --cooldown-seconds)
      [[ $# -ge 2 ]] || die "--cooldown-seconds requires a value"
      cooldown_seconds="$2"
      shift 2
      ;;
    --cooldown-seconds=*)
      cooldown_seconds="${1#*=}"
      shift
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
    --dry-run)
      dry_run=1
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

require_positive_int "attempts" "$attempts"
require_positive_int "timeout-seconds" "$timeout_seconds"
require_uint "settle-seconds" "$settle_seconds"
require_uint "cooldown-seconds" "$cooldown_seconds"
[[ "$appid" =~ ^[0-9]+$ ]] || die "appid must be a positive integer"

require_script "scripts/lib/common.sh"
require_script "scripts/launch-cs2.sh"

report_root="$log_dir/live-validation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$report_root"

trap 'status=$?; if [[ "$status" -ne 0 ]]; then cleanup_launch "signal"; fi' EXIT
trap 'cleanup_launch "interrupt"; exit 130' INT
trap 'cleanup_launch "terminated"; exit 143' TERM

print_plan
check_launch_script

if [[ "$dry_run" -eq 1 ]]; then
  dry_run_mode
  note ""
  note "Dry-run complete."
  exit 0
fi

resolve_runtime

for attempt_no in $(seq 1 "$attempts"); do
  if ! run_launch_attempt "$attempt_no"; then
    failures=$((failures + 1))
    note ""
    note "Repeated live validation failed on attempt $attempt_no"
    exit 1
  fi
done

note ""
note "Repeated live validation passed: $attempts/$attempts attempts showed AppID 730 process creation."
