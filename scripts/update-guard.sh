#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths
cs2_load_versions_lock

policy_file="$repo_root/config/update-policy.env"
env_guard_enforce="${CS2_UPDATE_GUARD_ENFORCE-__unset__}"
env_guard_block="${CS2_UPDATE_GUARD_BLOCK_ON_ANY_UPDATE-__unset__}"
env_guard_popup="${CS2_UPDATE_GUARD_SHOW_POPUP-__unset__}"
env_guard_checks="${CS2_UPDATE_GUARD_RUN_QUICK_CHECKS-__unset__}"
env_guard_safe="${CS2_UPDATE_GUARD_REQUIRE_SAFE_PROFILE-__unset__}"
env_guard_state_dir="${CS2_UPDATE_GUARD_STATE_DIR-__unset__}"
env_guard_baseline_file="${CS2_UPDATE_GUARD_BASELINE_FILE-__unset__}"
env_guard_report_file="${CS2_UPDATE_GUARD_REPORT_FILE-__unset__}"

if [[ -r "$policy_file" ]]; then
  # shellcheck disable=SC1090
  source "$policy_file"
fi

[[ "$env_guard_enforce" != "__unset__" ]] && CS2_UPDATE_GUARD_ENFORCE="$env_guard_enforce"
[[ "$env_guard_block" != "__unset__" ]] && CS2_UPDATE_GUARD_BLOCK_ON_ANY_UPDATE="$env_guard_block"
[[ "$env_guard_popup" != "__unset__" ]] && CS2_UPDATE_GUARD_SHOW_POPUP="$env_guard_popup"
[[ "$env_guard_checks" != "__unset__" ]] && CS2_UPDATE_GUARD_RUN_QUICK_CHECKS="$env_guard_checks"
[[ "$env_guard_safe" != "__unset__" ]] && CS2_UPDATE_GUARD_REQUIRE_SAFE_PROFILE="$env_guard_safe"
[[ "$env_guard_state_dir" != "__unset__" ]] && CS2_UPDATE_GUARD_STATE_DIR="$env_guard_state_dir"
[[ "$env_guard_baseline_file" != "__unset__" ]] && CS2_UPDATE_GUARD_BASELINE_FILE="$env_guard_baseline_file"
[[ "$env_guard_report_file" != "__unset__" ]] && CS2_UPDATE_GUARD_REPORT_FILE="$env_guard_report_file"

CS2_UPDATE_GUARD_ENFORCE="${CS2_UPDATE_GUARD_ENFORCE:-1}"
CS2_UPDATE_GUARD_BLOCK_ON_ANY_UPDATE="${CS2_UPDATE_GUARD_BLOCK_ON_ANY_UPDATE:-1}"
CS2_UPDATE_GUARD_SHOW_POPUP="${CS2_UPDATE_GUARD_SHOW_POPUP:-1}"
CS2_UPDATE_GUARD_RUN_QUICK_CHECKS="${CS2_UPDATE_GUARD_RUN_QUICK_CHECKS:-1}"
CS2_UPDATE_GUARD_REQUIRE_SAFE_PROFILE="${CS2_UPDATE_GUARD_REQUIRE_SAFE_PROFILE:-1}"

state_dir="${CS2_UPDATE_GUARD_STATE_DIR:-$CS2_MAC_ROOT/state}"
baseline_file="${CS2_UPDATE_GUARD_BASELINE_FILE:-$state_dir/approved-builds.env}"
report_file="${CS2_UPDATE_GUARD_REPORT_FILE:-$state_dir/update-guard-last-report.txt}"

mode="check"
show_prompt=0

usage() {
  cat <<'EOF_USAGE'
Usage: update-guard.sh [--check|--status|--approve-current|--codex-prompt] [--help]

Modes:
  --check           Validate current runtime/game versions against approved baseline.
                    Exit non-zero when launch should be blocked.
  --status          Print current and approved versions without blocking.
  --approve-current Approve current Steam/CS2/runtime versions as baseline.
  --codex-prompt    Print the Codex prompt to recover from a blocked launch.

Notes:
  - This guard cannot prove VAC safety. It enforces conservative policy gates.
  - For real gameplay validation after updates, test in Deathmatch before approval.
EOF_USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

bool_enabled() {
  [[ "${1:-0}" == "1" || "${1:-0}" == "true" || "${1:-0}" == "yes" ]]
}

steam_manifest_path() {
  printf '%s/package/steam_client_win64.manifest\n' "$CS2_MAC_STEAM_ROOT"
}

cs2_manifest_path() {
  printf '%s/steamapps/appmanifest_730.acf\n' "$CS2_MAC_STEAM_ROOT"
}

extract_steam_version() {
  local manifest
  manifest="$(steam_manifest_path)"
  [[ -f "$manifest" ]] || return 1
  awk -F'"' '/"version"[[:space:]]*"/{ print $4; exit }' "$manifest"
}

extract_cs2_buildid() {
  local manifest
  manifest="$(cs2_manifest_path)"
  [[ -f "$manifest" ]] || return 1
  awk -F'"' '/"buildid"[[:space:]]*"/{ print $4; exit }' "$manifest"
}

extract_wine_version() {
  local wine_bin
  wine_bin="${WINE_BIN:-}"
  if [[ -z "$wine_bin" ]]; then
    wine_bin="$(cs2_resolve_command wine64 wine || true)"
  fi
  [[ -n "$wine_bin" ]] || return 1
  "$wine_bin" --version 2>/dev/null | head -n 1
}

safe_profile_ok() {
  local profile="$repo_root/config/profile.safe.env"
  [[ -f "$profile" ]] || return 1
  grep -Eq '^(export[[:space:]]+)?WINEMSYNC=1$' "$profile" && \
    grep -Eq '^(export[[:space:]]+)?WINEESYNC=1$' "$profile" && \
    grep -Eq '^(export[[:space:]]+)?DXVK_ASYNC=0$' "$profile" && \
    grep -Eq '^(export[[:space:]]+)?MTL_HUD_ENABLED=0$' "$profile"
}

codex_prompt() {
  cat <<EOF_PROMPT
Codex prompt:
"CS2 update-guard blocked launch in /Users/rootb/Code/cs2-mac.
Read $report_file, inspect logs with ./scripts/collect-logs.sh,
run quick checks, validate in a Deathmatch only, and if stable update baseline with:
./scripts/update-guard.sh --approve-current"
EOF_PROMPT
}

show_popup() {
  local message="$1"
  if [[ "${CS2_UPDATE_GUARD_SHOW_POPUP:-0}" != "1" ]]; then
    return 0
  fi
  if ! command -v osascript >/dev/null 2>&1; then
    return 0
  fi
  CS2_GUARD_ALERT_MESSAGE="$message" osascript <<'EOF_OSA' >/dev/null 2>&1 || true
on run
  set alertMessage to system attribute "CS2_GUARD_ALERT_MESSAGE"
  display alert "CS2 launch blocked by update guard" message alertMessage as critical
end run
EOF_OSA
}

run_quick_checks() {
  local temp_dir
  local doctor_output
  local doctor_failures

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cs2-guard.XXXXXX")"
  trap 'rm -rf "$temp_dir"' RETURN

  if ! (cd "$repo_root" && CS2_SKIP_UPDATE_GUARD=1 ./scripts/verify-runtime.sh >"$temp_dir/verify-runtime.log" 2>&1); then
    printf 'quick-check failed: verify-runtime\n'
    return 1
  fi

  if ! (cd "$repo_root" && CS2_SKIP_UPDATE_GUARD=1 ./scripts/test-smoke.sh --verify-only >"$temp_dir/test-smoke.log" 2>&1); then
    printf 'quick-check failed: test-smoke --verify-only\n'
    return 1
  fi

  if ! (cd "$repo_root" && CS2_SKIP_UPDATE_GUARD=1 ./scripts/test-launch.sh --verify-only >"$temp_dir/test-launch.log" 2>&1); then
    printf 'quick-check failed: test-launch --verify-only\n'
    return 1
  fi

  doctor_output="$(cd "$repo_root" && CS2_SKIP_UPDATE_GUARD=1 ./scripts/doctor.sh 2>&1 || true)"
  printf '%s\n' "$doctor_output" >"$temp_dir/doctor.log"
  doctor_failures="$(printf '%s\n' "$doctor_output" | awk '/^Failures:/ {print $2}' | tail -n 1)"
  doctor_failures="${doctor_failures:-0}"

  if [[ ! "$doctor_failures" =~ ^[0-9]+$ ]]; then
    printf 'quick-check failed: doctor output parse error\n'
    return 1
  fi

  if (( doctor_failures > 0 )); then
    printf 'quick-check failed: doctor reported %s failures\n' "$doctor_failures"
    return 1
  fi

  printf 'quick-checks passed\n'
  return 0
}

load_baseline() {
  if [[ ! -f "$baseline_file" ]]; then
    return 1
  fi
  # shellcheck disable=SC1090
  source "$baseline_file"
  : "${CS2_APPROVED_STEAM_VERSION:=}"
  : "${CS2_APPROVED_CS2_BUILDID:=}"
  : "${CS2_APPROVED_WINE_VERSION:=}"
  : "${CS2_APPROVED_RUNTIME_CHANNEL:=}"
  return 0
}

write_baseline() {
  local steam_version="$1"
  local cs2_buildid="$2"
  local wine_version="$3"

  mkdir -p "$state_dir"
  cat >"$baseline_file" <<EOF_BASELINE
# Auto-generated by scripts/update-guard.sh --approve-current
CS2_APPROVED_STEAM_VERSION="$steam_version"
CS2_APPROVED_CS2_BUILDID="$cs2_buildid"
CS2_APPROVED_WINE_VERSION="$wine_version"
CS2_APPROVED_RUNTIME_CHANNEL="${CS2_RUNTIME_CHANNEL_DEFAULT}"
CS2_APPROVED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF_BASELINE
}

write_report() {
  local body="$1"
  mkdir -p "$state_dir"
  printf '%s\n' "$body" >"$report_file"
}

for arg in "$@"; do
  case "$arg" in
    --check)
      mode="check"
      ;;
    --status)
      mode="status"
      ;;
    --approve-current)
      mode="approve"
      ;;
    --codex-prompt)
      show_prompt=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $arg"
      ;;
  esac
done

if [[ "$show_prompt" == "1" ]]; then
  codex_prompt
  exit 0
fi

current_steam_version="$(extract_steam_version || true)"
current_cs2_buildid="$(extract_cs2_buildid || true)"
current_wine_version="$(extract_wine_version || true)"

if [[ -z "$current_steam_version" || -z "$current_cs2_buildid" || -z "$current_wine_version" ]]; then
  die "unable to detect current Steam/CS2/runtime versions"
fi

if [[ "$mode" == "approve" ]]; then
  write_baseline "$current_steam_version" "$current_cs2_buildid" "$current_wine_version"
  printf 'approved current baseline:\n'
  printf '  steam version: %s\n' "$current_steam_version"
  printf '  cs2 buildid:   %s\n' "$current_cs2_buildid"
  printf '  wine version:  %s\n' "$current_wine_version"
  printf '  baseline file: %s\n' "$baseline_file"
  exit 0
fi

baseline_present=1
if ! load_baseline; then
  baseline_present=0
fi

status_body="Update guard status\n"
status_body+="Current\n"
status_body+="- Steam version: $current_steam_version\n"
status_body+="- CS2 buildid: $current_cs2_buildid\n"
status_body+="- Wine version: $current_wine_version\n"
status_body+="- Runtime channel: ${CS2_RUNTIME_CHANNEL_DEFAULT}\n"

if (( baseline_present == 1 )); then
  status_body+="Approved\n"
  status_body+="- Steam version: ${CS2_APPROVED_STEAM_VERSION:-unset}\n"
  status_body+="- CS2 buildid: ${CS2_APPROVED_CS2_BUILDID:-unset}\n"
  status_body+="- Wine version: ${CS2_APPROVED_WINE_VERSION:-unset}\n"
  status_body+="- Runtime channel: ${CS2_APPROVED_RUNTIME_CHANNEL:-unset}\n"
else
  status_body+="Approved\n- no baseline file present ($baseline_file)\n"
fi

if [[ "$mode" == "status" ]]; then
  printf '%b' "$status_body"
  exit 0
fi

if ! bool_enabled "$CS2_UPDATE_GUARD_ENFORCE"; then
  printf 'update-guard: enforcement disabled\n'
  exit 0
fi

block_reason=""
run_check_reason=""
changes=()

if bool_enabled "$CS2_UPDATE_GUARD_REQUIRE_SAFE_PROFILE"; then
  if ! safe_profile_ok; then
    block_reason="safe profile policy mismatch (expected WINEMSYNC=1, WINEESYNC=1, DXVK_ASYNC=0, MTL_HUD_ENABLED=0)"
  fi
fi

if (( baseline_present == 0 )); then
  changes+=("approved baseline missing")
  run_check_reason="baseline missing"
else
  [[ "${CS2_APPROVED_STEAM_VERSION:-}" == "$current_steam_version" ]] || changes+=("steam version ${CS2_APPROVED_STEAM_VERSION:-unset} -> $current_steam_version")
  [[ "${CS2_APPROVED_CS2_BUILDID:-}" == "$current_cs2_buildid" ]] || changes+=("cs2 buildid ${CS2_APPROVED_CS2_BUILDID:-unset} -> $current_cs2_buildid")
  [[ "${CS2_APPROVED_WINE_VERSION:-}" == "$current_wine_version" ]] || changes+=("wine version ${CS2_APPROVED_WINE_VERSION:-unset} -> $current_wine_version")
  [[ "${CS2_APPROVED_RUNTIME_CHANNEL:-}" == "${CS2_RUNTIME_CHANNEL_DEFAULT}" ]] || changes+=("runtime channel ${CS2_APPROVED_RUNTIME_CHANNEL:-unset} -> ${CS2_RUNTIME_CHANNEL_DEFAULT}")

  if ((${#changes[@]} > 0)); then
    run_check_reason="approved baseline changed"
  fi
fi

quick_result="quick-checks skipped"
if [[ -n "$run_check_reason" ]] && bool_enabled "$CS2_UPDATE_GUARD_RUN_QUICK_CHECKS"; then
  if quick_output="$(run_quick_checks 2>&1)"; then
    quick_result="$quick_output"
  else
    quick_result="$quick_output"
    [[ -n "$block_reason" ]] || block_reason="quick checks failed after update delta"
  fi
fi

if [[ -z "$block_reason" ]] && [[ -n "$run_check_reason" ]] && bool_enabled "$CS2_UPDATE_GUARD_BLOCK_ON_ANY_UPDATE"; then
  block_reason="unapproved update delta detected ($run_check_reason)"
fi

report_body="$status_body"
if ((${#changes[@]} > 0)); then
  report_body+="Detected changes\n"
  for item in "${changes[@]}"; do
    report_body+="- $item\n"
  done
else
  report_body+="Detected changes\n- none\n"
fi
report_body+="Quick checks\n- $quick_result\n"

if [[ -n "$block_reason" ]]; then
  report_body+="Decision\n- BLOCKED: $block_reason\n"
  report_body+="\n"
  report_body+="Manual validation path\n"
  report_body+="1. Inspect report: $report_file\n"
  report_body+="2. Collect logs: ./scripts/collect-logs.sh\n"
  report_body+="3. Validate gameplay in Deathmatch only\n"
  report_body+="4. Approve baseline: ./scripts/update-guard.sh --approve-current\n"
  report_body+="\n"
  report_body+="This guard cannot guarantee VAC safety. It blocks unapproved drift to reduce risk.\n"

  write_report "$report_body"

  popup_message="Launch blocked: $block_reason"
  popup_message+=$'\n'
  popup_message+="See: $report_file"
  popup_message+=$'\n'
  popup_message+="Then run: ./scripts/update-guard.sh --codex-prompt"
  show_popup "$popup_message"

  printf '%b' "$report_body"
  codex_prompt
  exit 40
fi

report_body+="Decision\n- ALLOWED\n"
write_report "$report_body"
printf '%b' "$report_body"
exit 0
