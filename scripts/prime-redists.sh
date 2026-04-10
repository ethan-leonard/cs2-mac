#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "$script_dir/.." && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths

usage() {
  cat <<'USAGE'
Usage: prime-redists.sh [--force] [--skip-install] [--help]

Ensure Steam CommonRedist run-keys are present for CS2 prerequisites so
`RunningInstallScript` does not loop on every launch.

Options:
  --force         Always re-run redist installers before setting run-keys.
  --skip-install  Only set run-keys, never execute installers.
  --help          Show this help.
USAGE
}

force=0
skip_install=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      force=1
      shift
      ;;
    --skip-install)
      skip_install=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      cs2_die "unknown argument: $1"
      ;;
  esac
done

wine_bin="${WINE_BIN:-}"
if [[ -n "$wine_bin" ]]; then
  [[ -x "$wine_bin" ]] || cs2_die "WINE_BIN is set but not executable: $wine_bin"
elif ! wine_bin="$(cs2_resolve_command wine64 wine)"; then
  cs2_die "could not find wine64 or wine on PATH; set WINE_BIN explicitly"
fi

cs2_maybe_set_cx_root_from_wine_bin "$wine_bin"

export WINEPREFIX="${WINEPREFIX:-$CS2_MAC_PREFIX}"
export WINEDEBUG="${WINEDEBUG:--all}"

steam_root="$WINEPREFIX/$STEAM_ROOT_REL"
cs2_root="$steam_root/steamapps/common/Counter-Strike Global Offensive"
runasadmin_vdf="$cs2_root/runasadmin.vdf"

if [[ ! -f "$runasadmin_vdf" ]]; then
  cs2_warn "runasadmin.vdf not found; skipping redist priming: $runasadmin_vdf"
  exit 0
fi

vc_x86_runkey="$(sed -n 's/^[[:space:]]*"x86 \([0-9.][0-9.]*\) 1".*/x86 \1/p' "$runasadmin_vdf" | head -n 1)"
vc_x64_runkey="$(sed -n 's/^[[:space:]]*"x64 \([0-9.][0-9.]*\) 1".*/x64 \1/p' "$runasadmin_vdf" | head -n 1)"
dx_runkey="$(sed -n 's/^[[:space:]]*"dxsetup 1".*/dxsetup/p' "$runasadmin_vdf" | head -n 1)"

vc_x86_runkey="${vc_x86_runkey:-x86 14.28.29334.0}"
vc_x64_runkey="${vc_x64_runkey:-x64 14.28.29334.0}"
dx_runkey="${dx_runkey:-dxsetup}"

reg_key_vc='HKLM\Software\Valve\Steam\Apps\CommonRedist\vcredist\2019'
reg_key_dx='HKLM\Software\Valve\Steam\Apps\CommonRedist\DirectX\Jun2010'
sentinel_system32="$WINEPREFIX/drive_c/windows/system32"
sentinel_syswow64="$WINEPREFIX/drive_c/windows/syswow64"

has_redist_markers() {
  "$wine_bin" reg query "$reg_key_vc" /v "$vc_x86_runkey" >/dev/null 2>&1 \
    && "$wine_bin" reg query "$reg_key_vc" /v "$vc_x64_runkey" >/dev/null 2>&1 \
    && "$wine_bin" reg query "$reg_key_dx" /v "$dx_runkey" >/dev/null 2>&1
}

run_installer_if_present() {
  local label="$1"
  shift
  local cmd=("$@")

  if [[ ! -f "${cmd[0]}" ]]; then
    cs2_warn "missing $label installer; skipping: ${cmd[0]}"
    return 0
  fi

  cs2_log "running $label installer"
  "${cmd[@]}"
}

if [[ "$force" -eq 0 ]] && has_redist_markers; then
  cs2_log "redist run-keys already present; skipping"
  exit 0
fi

sentinels_present=0
if [[ -f "$sentinel_system32/vcruntime140.dll" \
  && -f "$sentinel_system32/d3dx9_43.dll" \
  && -f "$sentinel_system32/xinput1_3.dll" \
  && -f "$sentinel_syswow64/vcruntime140.dll" \
  && -f "$sentinel_syswow64/d3dx9_43.dll" \
  && -f "$sentinel_syswow64/xinput1_3.dll" ]]; then
  sentinels_present=1
fi

if [[ "$skip_install" -eq 0 ]]; then
  if [[ "$force" -eq 1 || "$sentinels_present" -eq 0 ]]; then
    shared_redist="$steam_root/steamapps/common/Steamworks Shared/_CommonRedist"
    run_installer_if_present "VC++ x86" \
      "$wine_bin" \
      "$shared_redist/vcredist/2019/Microsoft Visual C++ 2019 x86.cmd"
    run_installer_if_present "VC++ x64" \
      "$wine_bin" \
      "$shared_redist/vcredist/2019/Microsoft Visual C++ 2019 x64.cmd"
    run_installer_if_present "DirectX Jun2010" \
      "$wine_bin" \
      "$shared_redist/DirectX/Jun2010/DXSETUP.exe" \
      /silent
  else
    cs2_log "redist DLL sentinels are already present; skipping installer execution"
  fi
fi

cs2_log "writing CommonRedist run-keys"
"$wine_bin" reg add "$reg_key_vc" /v "$vc_x86_runkey" /t REG_DWORD /d 1 /f >/dev/null
"$wine_bin" reg add "$reg_key_vc" /v "$vc_x64_runkey" /t REG_DWORD /d 1 /f >/dev/null
"$wine_bin" reg add "$reg_key_dx" /v "$dx_runkey" /t REG_DWORD /d 1 /f >/dev/null

if has_redist_markers; then
  cs2_log "redist run-keys are set"
else
  cs2_die "failed to confirm redist run-keys after priming"
fi
