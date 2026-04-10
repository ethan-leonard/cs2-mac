#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths

usage() {
  cat <<'EOF'
Usage: doctor.sh

Checks the local CS2 wrapper environment for:
  - runtime binaries
  - prefix structure
  - Steam executable
  - CS2 manifest/content
  - monitor basics where available

Options:
  --cleanup-runtime     Tear down prefix-scoped Steam/Wine processes before checks

Environment overrides:
  CS2_MAC_ROOT          Base support directory
  CS2_MAC_PREFIX        Wine prefix root
  CS2_MAC_LOGS          Log root directory
  CS2_HOST_STEAM_ROOT   Native Steam library root
  CROSSOVER_STEAM_BOTTLE Legacy CrossOver bottle root
  WINE_BIN              Preferred wine binary
  WINESERVER_BIN        Preferred wineserver binary

EOF
}

cleanup_runtime=0
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --cleanup-runtime)
      cleanup_runtime=1
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

project_root="$CS2_MAC_ROOT"
prefix_root="$CS2_MAC_PREFIX"
prefix_steam_root="$prefix_root/$STEAM_ROOT_REL"
prefix_steamapps="$prefix_steam_root/steamapps"
host_steam_root="${CS2_HOST_STEAM_ROOT:-$HOME/Library/Application Support/Steam}"
host_steamapps="$host_steam_root/steamapps"
cross_steam_root="$CS2_CROSSOVER_STEAM_ROOT"
cross_steamapps="$cross_steam_root/steamapps"
steam_exe_path="$prefix_steam_root/Steam.exe"

failures=0
warnings=0

section() {
  printf '\n== %s ==\n' "$1"
}

ok() {
  printf '[OK] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1"
  warnings=$((warnings + 1))
}

fail() {
  printf '[FAIL] %s\n' "$1"
  failures=$((failures + 1))
}

check_dir() {
  local label="$1"
  local path="$2"
  if [ -d "$path" ]; then
    ok "$label: $path"
  else
    fail "$label missing: $path"
  fi
}

check_file() {
  local label="$1"
  local path="$2"
  if [ -f "$path" ]; then
    ok "$label: $path"
  else
    fail "$label missing: $path"
  fi
}

probe_tool() {
  local label="$1"
  shift

  local candidate=""
  local found=""
  local version_output=""

  for candidate in "$@"; do
    if [ -z "$candidate" ]; then
      continue
    fi

    if [ "${candidate#*/}" != "$candidate" ]; then
      if [ -x "$candidate" ]; then
        found="$candidate"
        break
      fi
    else
      if command -v "$candidate" >/dev/null 2>&1; then
        found="$(command -v "$candidate")"
        break
      fi
    fi
  done

  if [ -n "$found" ]; then
    ok "$label: $found"
    version_output="$("$found" --version 2>/dev/null || true)"
    if [ -n "$version_output" ]; then
      printf '    %s\n' "$(printf '%s' "$version_output" | head -n 1)"
    fi
  else
    fail "$label not found"
  fi
}

check_runtime() {
  section "Runtime Binaries"
  probe_tool "wine" "${WINE_BIN:-}" wine64 wine
  probe_tool "wineserver" "${WINESERVER_BIN:-}" wineserver
  probe_tool "tar" tar
  probe_tool "stat" stat
  probe_tool "system_profiler" system_profiler
}

check_prefix() {
  section "Prefix Structure"
  check_dir "project support root" "$project_root"
  check_dir "prefix root" "$prefix_root"
  check_dir "prefix drive_c" "$prefix_root/drive_c"
  check_dir "Program Files (x86)" "$prefix_root/drive_c/Program Files (x86)"
  check_dir "Steam root" "$prefix_steam_root"
  check_dir "steamapps" "$prefix_steamapps"
  check_dir "steamapps/common" "$prefix_steamapps/common"
  if [ -f "$prefix_steamapps/libraryfolders.vdf" ]; then
    ok "steamapps/libraryfolders.vdf: $prefix_steamapps/libraryfolders.vdf"
  else
    warn "steamapps/libraryfolders.vdf missing (Steam will generate this after first successful launch)"
  fi
}

check_steam_executable() {
  section "Steam Executable"
  steam_exe_path="$(cs2_resolve_steam_exe_path "$prefix_root" "$STEAM_EXE_REL" || true)"
  if [ -f "$steam_exe_path" ]; then
    ok "prefix steam executable: $steam_exe_path"
  else
    fail "prefix steam executable missing under: $prefix_steam_root"
  fi

  if command -v steam >/dev/null 2>&1; then
    ok "host steam command: $(command -v steam)"
  else
    warn "host steam command not found in PATH"
  fi

  if [ -x "/Applications/Steam.app/Contents/MacOS/Steam" ]; then
    ok "native Steam app executable: /Applications/Steam.app/Contents/MacOS/Steam"
  else
    warn "native Steam app executable not present at /Applications/Steam.app"
  fi
}

check_cs2_content() {
  section "CS2 Manifest and Content"

  check_file "prefix appmanifest_730.acf" "$prefix_steamapps/appmanifest_730.acf"
  check_dir "prefix CS2 install dir" "$prefix_steamapps/common/Counter-Strike Global Offensive"
  check_file "prefix CS2 core content" "$prefix_steamapps/common/Counter-Strike Global Offensive/game/csgo/pak01_dir.vpk"
  check_dir "prefix CS2 win64 binaries" "$prefix_steamapps/common/Counter-Strike Global Offensive/game/bin/win64"
  check_file "prefix CS2 signatures" "$prefix_steamapps/common/Counter-Strike Global Offensive/game/bin/win64/csgo.signatures"

  if [ -f "$host_steamapps/appmanifest_730.acf" ]; then
    ok "host Steam appmanifest_730.acf: $host_steamapps/appmanifest_730.acf"
  else
    warn "host Steam appmanifest_730.acf not present"
  fi

  if [ -f "$host_steamapps/common/Counter-Strike Global Offensive/game/csgo/pak01_dir.vpk" ]; then
    ok "host Steam CS2 content present"
  else
    warn "host Steam CS2 content not present"
  fi

  if [ -f "$cross_steamapps/appmanifest_730.acf" ]; then
    ok "legacy CrossOver appmanifest_730.acf: $cross_steamapps/appmanifest_730.acf"
  else
    warn "legacy CrossOver appmanifest_730.acf not present"
  fi
}

check_monitor_basics() {
  section "Monitor Basics"

  if ! command -v system_profiler >/dev/null 2>&1; then
    warn "system_profiler is unavailable"
    return
  fi

  local display_snapshot
  display_snapshot="$(system_profiler SPDisplaysDataType 2>/dev/null | awk '
    /Chipset Model:|Display Type:|Resolution:|Refresh Rate:|Main Display:|Mirror:|Online:/ {
      print
    }
  ')"

  if [ -n "$display_snapshot" ]; then
    printf '%s\n' "$display_snapshot"
    ok "display information captured"
  else
    warn "no display information returned"
  fi
}

check_disk_space() {
  section "Disk Space"
  if df -h "$HOME" "$project_root" 2>/dev/null; then
    ok "disk usage snapshot captured"
  else
    warn "disk usage snapshot unavailable"
  fi
}

main() {
  printf 'CS2-Mac doctor\n'
  printf 'Repo: %s\n' "$repo_root"
  printf 'Project root: %s\n' "$project_root"
  printf 'Prefix root: %s\n' "$prefix_root"

  if [ "$cleanup_runtime" -eq 1 ]; then
    section "Runtime Cleanup"
    if "$script_dir/cleanup-runtime.sh" --prefix "$prefix_root" --steam-exe "$steam_exe_path"; then
      ok "runtime cleanup completed"
    else
      fail "runtime cleanup reported a failure"
    fi
  fi

  check_runtime
  check_prefix
  check_steam_executable
  check_cs2_content
  check_monitor_basics
  check_disk_space

  section "Summary"
  printf 'Warnings: %d\n' "$warnings"
  printf 'Failures: %d\n' "$failures"

  if [ "$failures" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
