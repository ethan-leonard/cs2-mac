#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
cs2_load_paths

cs2_info() {
  cs2_log "[INFO] $*"
}

cs2_resolve_path() {
  local input="${1:-}"
  [ -n "$input" ] || cs2_die "internal error: missing path"

  case "$input" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${input#~/}"
      ;;
    /*)
      printf '%s\n' "$input"
      ;;
    *)
      printf '%s/%s\n' "$PWD" "$input"
      ;;
  esac
}

cs2_default_prefix_path() {
  printf '%s\n' "$CS2_MAC_PREFIX"
}

cs2_prefix_path() {
  if [ -n "${CS2_PREFIX_PATH:-}" ]; then
    cs2_resolve_path "$CS2_PREFIX_PATH"
  else
    cs2_default_prefix_path
  fi
}

cs2_steam_root_from_prefix() {
  local prefix="$1"
  printf '%s\n' "$prefix/$STEAM_ROOT_REL"
}

cs2_default_steam_root() {
  printf '%s\n' "$CS2_MAC_STEAM_ROOT"
}

cs2_steam_root_path() {
  if [ -n "${CS2_STEAM_ROOT:-}" ]; then
    cs2_resolve_path "$CS2_STEAM_ROOT"
  else
    cs2_default_steam_root
  fi
}

cs2_ensure_symlink() {
  local target="$1"
  local link="$2"

  if [ -L "$link" ]; then
    local current
    current="$(readlink "$link")"
    if [ "$current" != "$target" ]; then
      cs2_die "refusing to replace existing symlink $link -> $current (expected $target)"
    fi
    return 0
  fi

  if [ -e "$link" ]; then
    cs2_die "refusing to overwrite existing path: $link"
  fi

  ln -s "$target" "$link"
}

cs2_run_logged() {
  local log_file="$1"
  shift

  cs2_ensure_dir "$(dirname "$log_file")"
  : >>"$log_file"

  if "$@" >>"$log_file" 2>&1; then
    return 0
  fi

  local status=$?
  cs2_warn "command failed; showing the tail of $log_file"
  tail -n 40 "$log_file" >&2 || true
  return "$status"
}

cs2_seed_steam_from_existing() {
  local source_root="$1"
  local target_root="$2"
  local source_steam_exe=""
  local path

  [ -d "$source_root" ] || return 0
  if [ -f "$source_root/steam.exe" ]; then
    source_steam_exe="$source_root/steam.exe"
  elif [ -f "$source_root/Steam.exe" ]; then
    source_steam_exe="$source_root/Steam.exe"
  fi
  [ -n "$source_steam_exe" ] || return 0

  if [ -f "$target_root/steam.exe" ] || [ -f "$target_root/Steam.exe" ]; then
    return 0
  fi

  cs2_info "steam.exe not found in target prefix; seeding minimal Steam bootstrap files from: $source_root"

  cp -p "$source_steam_exe" "$target_root/steam.exe"

  for path in \
    "steam.dll" \
    "steamclient.dll" \
    "steamclient64.dll" \
    "tier0_s.dll" \
    "vstdlib_s.dll"; do
    if [ -f "$source_root/$path" ]; then
      cp -p "$source_root/$path" "$target_root/$path"
    fi
  done

  for path in "package" "bin"; do
    if [ -d "$source_root/$path" ] && [ ! -d "$target_root/$path" ]; then
      cp -R "$source_root/$path" "$target_root/$path"
    fi
  done
}

cs2_bootstrap_steam_layout() {
  local prefix="$1"
  local steam_root="$2"
  local log_dir="$3"
  local wineboot_log="$log_dir/wineboot.log"

  cs2_ensure_dir "$prefix"
  cs2_ensure_dir "$log_dir"
  cs2_ensure_dir "$(dirname "$steam_root")"

  if [ ! -e "$prefix/system.reg" ] && command -v wineboot >/dev/null 2>&1 && [ "${CS2_SKIP_WINEBOOT:-0}" != "1" ]; then
    cs2_info "initializing the Wine prefix with wineboot"
    if [ -z "${WINEARCH:-}" ]; then
      export WINEARCH=win64
    fi
    export WINEPREFIX="$prefix"
    export WINEDEBUG="${WINEDEBUG:-fixme-all}"
    cs2_run_logged "$wineboot_log" wineboot -u
  elif [ ! -e "$prefix/system.reg" ]; then
    cs2_warn "wineboot is not available; creating the prefix layout manually"
  fi

  cs2_ensure_dir "$prefix/drive_c"
  cs2_ensure_dir "$prefix/dosdevices"
  cs2_ensure_dir "$prefix/drive_c/users/root"
  cs2_ensure_dir "$prefix/drive_c/users/Public"
  cs2_ensure_dir "$prefix/drive_c/Program Files (x86)"
  cs2_ensure_dir "$steam_root"
  cs2_ensure_dir "$steam_root/steamapps"
  cs2_ensure_dir "$steam_root/steamapps/common"
  cs2_ensure_dir "$steam_root/steamapps/downloading"
  cs2_ensure_dir "$steam_root/steamapps/temp"
  cs2_ensure_dir "$steam_root/steamapps/shadercache"
  cs2_ensure_dir "$steam_root/steamapps/workshop"
  cs2_ensure_dir "$steam_root/steamapps/workshop/content"
  cs2_ensure_dir "$steam_root/steamapps/workshop/downloads"
  cs2_ensure_dir "$steam_root/config"
  cs2_ensure_dir "$steam_root/userdata"
  cs2_ensure_dir "$steam_root/logs"
  cs2_ensure_dir "$steam_root/package"

  if [ ! -e "$prefix/dosdevices/c:" ]; then
    cs2_ensure_symlink "../drive_c" "$prefix/dosdevices/c:"
  fi

  if [ ! -e "$prefix/dosdevices/z:" ]; then
    cs2_ensure_symlink "/" "$prefix/dosdevices/z:"
  fi

  if [ "${CS2_SKIP_STEAM_SEED:-0}" != "1" ]; then
    cs2_seed_steam_from_existing "${CS2_CROSSOVER_STEAM_ROOT}" "$steam_root"
  fi

  cs2_info "prefix is ready: $prefix"
  cs2_info "steam root is ready: $steam_root"
}
