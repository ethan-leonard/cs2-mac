#!/usr/bin/env bash
set -euo pipefail

cs2_log() {
  printf '%s\n' "$*"
}

cs2_warn() {
  printf 'warning: %s\n' "$*" >&2
}

cs2_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cs2_common_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
}

cs2_repo_root() {
  cd -- "$(cs2_common_dir)/../.." && pwd
}

cs2_paths_env_path() {
  printf '%s/config/paths.env\n' "$(cs2_repo_root)"
}

cs2_load_paths() {
  local paths_path
  local env_cs2_mac_root="${CS2_MAC_ROOT:-}"
  local env_cs2_mac_prefix="${CS2_MAC_PREFIX:-}"
  local env_cs2_mac_logs="${CS2_MAC_LOGS:-}"
  local env_cs2_mac_cache="${CS2_MAC_CACHE:-}"
  local env_cs2_mac_runtime_bin="${CS2_MAC_RUNTIME_BIN:-}"
  local env_crossover_bottle="${CROSSOVER_STEAM_BOTTLE:-}"
  local env_steam_root_rel="${STEAM_ROOT_REL:-}"
  paths_path="$(cs2_paths_env_path)"
  if [[ ! -f "$paths_path" ]]; then
    cs2_die "missing paths config: $paths_path"
  fi

  # shellcheck disable=SC1090
  source "$paths_path"

  [[ -n "$env_cs2_mac_root" ]] && CS2_MAC_ROOT="$env_cs2_mac_root"
  [[ -n "$env_cs2_mac_prefix" ]] && CS2_MAC_PREFIX="$env_cs2_mac_prefix"
  [[ -n "$env_cs2_mac_logs" ]] && CS2_MAC_LOGS="$env_cs2_mac_logs"
  [[ -n "$env_cs2_mac_cache" ]] && CS2_MAC_CACHE="$env_cs2_mac_cache"
  [[ -n "$env_cs2_mac_runtime_bin" ]] && CS2_MAC_RUNTIME_BIN="$env_cs2_mac_runtime_bin"
  [[ -n "$env_crossover_bottle" ]] && CROSSOVER_STEAM_BOTTLE="$env_crossover_bottle"
  [[ -n "$env_steam_root_rel" ]] && STEAM_ROOT_REL="$env_steam_root_rel"

  : "${CS2_MAC_ROOT:?CS2_MAC_ROOT is required in config/paths.env}"
  : "${CS2_MAC_PREFIX:?CS2_MAC_PREFIX is required in config/paths.env}"
  : "${CS2_MAC_LOGS:?CS2_MAC_LOGS is required in config/paths.env}"
  : "${CS2_MAC_CACHE:?CS2_MAC_CACHE is required in config/paths.env}"
  : "${CS2_MAC_RUNTIME_BIN:?CS2_MAC_RUNTIME_BIN is required in config/paths.env}"
  : "${CROSSOVER_STEAM_BOTTLE:?CROSSOVER_STEAM_BOTTLE is required in config/paths.env}"
  : "${STEAM_ROOT_REL:?STEAM_ROOT_REL is required in config/paths.env}"

  CS2_CROSSOVER_STEAM_ROOT="$CROSSOVER_STEAM_BOTTLE/$STEAM_ROOT_REL"
  CS2_MAC_STEAM_ROOT="$CS2_MAC_PREFIX/$STEAM_ROOT_REL"

  if [[ -d "$CS2_MAC_RUNTIME_BIN" ]]; then
    case ":$PATH:" in
      *":$CS2_MAC_RUNTIME_BIN:"*) ;;
      *) export PATH="$CS2_MAC_RUNTIME_BIN:$PATH" ;;
    esac
  fi
}

cs2_ensure_dir() {
  mkdir -p "$1"
}

cs2_versions_lock_path() {
  printf '%s/config/versions.lock\n' "$(cs2_repo_root)"
}

cs2_load_versions_lock() {
  local lock_path
  lock_path="$(cs2_versions_lock_path)"
  if [[ ! -f "$lock_path" ]]; then
    cs2_die "missing versions lock: $lock_path"
  fi
  # shellcheck disable=SC1090
  source "$lock_path"
}

cs2_require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    cs2_die "required command not found: $cmd"
  fi
}

cs2_resolve_command() {
  local candidate
  for candidate in "$@"; do
    if [[ -z "$candidate" ]]; then
      continue
    fi
    if [[ "$candidate" == */* ]]; then
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    elif command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

cs2_maybe_set_cx_root_from_wine_bin() {
  local wine_bin="${1:-}"
  local resolved
  local target
  local cx_prefix

  if [[ -n "${CX_ROOT:-}" || -z "$wine_bin" ]]; then
    return 0
  fi

  resolved="$wine_bin"
  if [[ -L "$resolved" ]]; then
    target="$(readlink "$resolved" || true)"
    if [[ -n "$target" ]]; then
      if [[ "$target" != /* ]]; then
        target="$(cd -- "$(dirname -- "$resolved")" && pwd)/$target"
      fi
      resolved="$target"
    fi
  fi

  if [[ "$resolved" == *"/CrossOver.app/Contents/SharedSupport/CrossOver/"* ]]; then
    cx_prefix="${resolved%%/CrossOver.app/Contents/SharedSupport/CrossOver/*}"
    export CX_ROOT="$cx_prefix/CrossOver.app/Contents/SharedSupport/CrossOver"
  fi
}

cs2_resolve_steam_exe_path() {
  local prefix="${1:-}"
  local rel="${2:-${STEAM_EXE_REL:-drive_c/Program Files (x86)/Steam/steam.exe}}"
  local candidate
  local dirname_path
  local basename_path
  local fallback_basename

  [[ -n "$prefix" ]] || return 1

  candidate="$prefix/$rel"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  dirname_path="$(dirname -- "$candidate")"
  basename_path="$(basename -- "$candidate")"
  fallback_basename="$basename_path"

  if [[ "$basename_path" == "steam.exe" ]]; then
    fallback_basename="Steam.exe"
  elif [[ "$basename_path" == "Steam.exe" ]]; then
    fallback_basename="steam.exe"
  fi

  if [[ -f "$dirname_path/$fallback_basename" ]]; then
    printf '%s\n' "$dirname_path/$fallback_basename"
    return 0
  fi

  if [[ -f "$dirname_path/Steam.exe" ]]; then
    printf '%s\n' "$dirname_path/Steam.exe"
    return 0
  fi

  if [[ -f "$dirname_path/steam.exe" ]]; then
    printf '%s\n' "$dirname_path/steam.exe"
    return 0
  fi

  return 1
}

cs2_prefix_runtime_candidate_pids() {
  local prefix_root="${1:-}"
  local steam_exe="${2:-}"
  local exclude_pid="${3:-}"

  [[ -n "$prefix_root" ]] || return 0

  ps -axo pid=,ppid=,command= | awk -v prefix="$prefix_root" -v exclude_pid="$exclude_pid" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function is_numeric(value) {
      return value ~ /^[0-9]+$/
    }
    function is_runtime_cmd(value, lower) {
      lower = tolower(value)
      if (lower ~ /(^|[[:space:]])(bash|zsh|sh|awk)([[:space:]]|$)/) {
        return 0
      }
      return (lower ~ /(wine64|wineserver|winedevice|steam\.exe|steamwebhelper\.exe|cs2\.exe|wineloader)/)
    }

    {
      pid=$1
      ppid=$2
      $1=""
      $2=""
      cmd=trim($0)
      if (!is_numeric(pid) || !is_numeric(ppid)) {
        next
      }
      if ((pid + 0) <= 1) {
        next
      }
      if (exclude_pid != "" && pid == exclude_pid) {
        next
      }
      if (is_runtime_cmd(cmd) && index(cmd, prefix) > 0) {
        print pid
      }
    }
  ' | sort -n
}

cs2_prefix_runtime_process_table() {
  local prefix_root="${1:-}"
  local steam_exe="${2:-}"
  local exclude_pid="${3:-}"

  [[ -n "$prefix_root" ]] || return 0

  ps -axo pid=,ppid=,command= | awk -v prefix="$prefix_root" -v exclude_pid="$exclude_pid" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function is_numeric(value) {
      return value ~ /^[0-9]+$/
    }
    function is_runtime_cmd(value, lower) {
      lower = tolower(value)
      if (lower ~ /(^|[[:space:]])(bash|zsh|sh|awk)([[:space:]]|$)/) {
        return 0
      }
      return (lower ~ /(wine64|wineserver|winedevice|steam\.exe|steamwebhelper\.exe|cs2\.exe|wineloader)/)
    }

    {
      pid=$1
      ppid=$2
      $1=""
      $2=""
      cmd=trim($0)
      if (!is_numeric(pid) || !is_numeric(ppid)) {
        next
      }
      if ((pid + 0) <= 1) {
        next
      }
      if (exclude_pid != "" && pid == exclude_pid) {
        next
      }
      if (is_runtime_cmd(cmd) && index(cmd, prefix) > 0) {
        printf "%s\t%s\t%s\n", pid, ppid, cmd
      }
    }
  ' | sort -n
}

cs2_cleanup_prefix_runtime() {
  local prefix_root="${1:-}"
  local steam_exe="${2:-}"
  local wineserver_bin="${3:-}"
  local self_pid="$$"

  [[ -n "$prefix_root" ]] || cs2_die "cleanup requires a prefix path"

  cs2_log "cleanup: target prefix: $prefix_root"
  if [[ -n "$steam_exe" ]]; then
    cs2_log "cleanup: steam executable: $steam_exe"
  fi

  if [[ -n "$wineserver_bin" ]]; then
    if [[ -x "$wineserver_bin" ]]; then
      cs2_log "cleanup: stopping wineserver for this prefix"
      WINEPREFIX="$prefix_root" "$wineserver_bin" -k >/dev/null 2>&1 || true
    else
      cs2_warn "cleanup: wineserver path is not executable: $wineserver_bin"
    fi
  else
    cs2_warn "cleanup: wineserver not found on PATH; skipping prefix server shutdown"
  fi

  sleep 1

  local -a candidate_pids=()
  local candidate_pid
  while IFS= read -r candidate_pid; do
    [[ -n "$candidate_pid" ]] || continue
    candidate_pids+=("$candidate_pid")
  done < <(cs2_prefix_runtime_candidate_pids "$prefix_root" "$steam_exe" "$self_pid")

  if ((${#candidate_pids[@]} == 0)); then
    cs2_log "cleanup: no prefix-scoped Steam/Wine processes remain"
    return 0
  fi

  cs2_log "cleanup: prefix-scoped process tree:"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    cs2_log "  $line"
  done < <(cs2_prefix_runtime_process_table "$prefix_root" "$steam_exe" "$self_pid")

  cs2_log "cleanup: sending SIGTERM to ${#candidate_pids[@]} process(es)"
  kill "${candidate_pids[@]}" >/dev/null 2>&1 || true
  sleep 1

  local -a remaining_pids=()
  while IFS= read -r candidate_pid; do
    [[ -n "$candidate_pid" ]] || continue
    remaining_pids+=("$candidate_pid")
  done < <(cs2_prefix_runtime_candidate_pids "$prefix_root" "$steam_exe" "$self_pid")

  if ((${#remaining_pids[@]} == 0)); then
    cs2_log "cleanup: all prefix-scoped processes exited after SIGTERM"
    return 0
  fi

  cs2_warn "cleanup: ${#remaining_pids[@]} process(es) still alive after SIGTERM; sending SIGKILL"
  kill -KILL "${remaining_pids[@]}" >/dev/null 2>&1 || true
  sleep 1

  local -a final_pids=()
  while IFS= read -r candidate_pid; do
    [[ -n "$candidate_pid" ]] || continue
    final_pids+=("$candidate_pid")
  done < <(cs2_prefix_runtime_candidate_pids "$prefix_root" "$steam_exe" "$self_pid")

  if ((${#final_pids[@]} == 0)); then
    cs2_log "cleanup: all prefix-scoped processes exited after SIGKILL"
  else
    cs2_warn "cleanup: lingering prefix-scoped process ids: ${final_pids[*]}"
    return 1
  fi
}

cs2_help_common() {
  cat <<'EOF_HELP'
Common environment variables:
  CS2_RUNTIME_CHANNEL             Override runtime channel from versions.lock.
  CS2_RUNTIME_BREW_TAP            Override Homebrew tap used by the brew channel.
  CS2_RUNTIME_BREW_TAP_URL        Override the Git URL used to tap the brew channel.
  CS2_RUNTIME_BREW_FORMULA        Override Homebrew formula used by the brew channel.
  CS2_RUNTIME_INSTALLER_PATH      Override pkg path for the manual_pkg channel.
  CS2_MIN_FREE_GB                 Override minimum free disk threshold.
EOF_HELP
}

cs2_free_gb_for_path() {
  local target_path="$1"
  df -Pk "$target_path" | awk 'NR == 2 { printf "%d\n", int($4 / 1024 / 1024) }'
}

cs2_version_at_least() {
  local minimum="$1"
  local current="$2"
  awk -v minimum="$minimum" -v current="$current" '
    function split_version(version, parts,    count, i) {
      count = split(version, parts, ".")
      for (i = 1; i <= 3; i++) {
        if (i > count || parts[i] == "") {
          parts[i] = 0
        }
      }
    }

    function compare_versions(minimum, current,    min_parts, cur_parts, i, min_value, cur_value) {
      split_version(minimum, min_parts)
      split_version(current, cur_parts)
      for (i = 1; i <= 3; i++) {
        min_value = min_parts[i] + 0
        cur_value = cur_parts[i] + 0
        if (cur_value > min_value) {
          return 1
        }
        if (cur_value < min_value) {
          return 0
        }
      }
      return 1
    }

    BEGIN {
      exit(compare_versions(minimum, current) ? 0 : 1)
    }
  '
}
