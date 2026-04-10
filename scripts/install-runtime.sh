#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage: install-runtime.sh [--help]

Installs the pinned CS2 runtime channel from config/versions.lock.

Supported channels:
  - crossover_local  Use locally installed CrossOver runtime binaries (default)
  - brew_tap         Homebrew tap install
  - manual_pkg    Install from a local .pkg path provided via env var

This script does not touch CrossOver and does not perform silent upgrades.
EOF_USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 ]]; then
  printf 'error: unexpected argument: %s\n' "$1" >&2
  usage >&2
  exit 2
fi

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cs2_load_paths
cs2_load_versions_lock

CS2_RUNTIME_CHANNEL="${CS2_RUNTIME_CHANNEL:-${CS2_RUNTIME_CHANNEL_DEFAULT}}"
CS2_RUNTIME_BREW_TAP="${CS2_RUNTIME_BREW_TAP:-${CS2_RUNTIME_BREW_TAP_DEFAULT}}"
CS2_RUNTIME_BREW_TAP_URL="${CS2_RUNTIME_BREW_TAP_URL:-${CS2_RUNTIME_BREW_TAP_URL_DEFAULT}}"
CS2_RUNTIME_BREW_FORMULA="${CS2_RUNTIME_BREW_FORMULA:-${CS2_RUNTIME_BREW_FORMULA_DEFAULT}}"
CS2_RUNTIME_MANUAL_PKG_PATH="${CS2_RUNTIME_MANUAL_PKG_PATH:-${CS2_RUNTIME_MANUAL_PKG_PATH_DEFAULT}}"
CS2_RUNTIME_CROSSOVER_WINE="${CS2_RUNTIME_CROSSOVER_WINE:-${CS2_RUNTIME_CROSSOVER_WINE_DEFAULT}}"
CS2_RUNTIME_CROSSOVER_WINESERVER="${CS2_RUNTIME_CROSSOVER_WINESERVER:-${CS2_RUNTIME_CROSSOVER_WINESERVER_DEFAULT}}"

cs2_require_command sw_vers
cs2_require_command uname

arch_name="$(uname -m)"
if [[ "$arch_name" != "arm64" ]]; then
  cs2_die "this installer is intended for Apple Silicon; found $arch_name"
fi

if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
  :
else
  cs2_warn "Rosetta is not currently installed; runtime installation may still work, but the prerequisite check will fail"
fi

runtime_is_installed() {
  command -v wine >/dev/null 2>&1 && command -v wineserver >/dev/null 2>&1
}

install_brew_tap() {
  cs2_require_command brew
  HOMEBREW_NO_AUTO_UPDATE=1 brew tap | grep -Fxq "$CS2_RUNTIME_BREW_TAP" || {
    cs2_log "tapping $CS2_RUNTIME_BREW_TAP"
    HOMEBREW_NO_AUTO_UPDATE=1 brew tap "$CS2_RUNTIME_BREW_TAP" "$CS2_RUNTIME_BREW_TAP_URL"
  }

  if runtime_is_installed; then
    cs2_log "runtime already installed; skipping"
    return 0
  fi

  cs2_log "installing $CS2_RUNTIME_BREW_TAP/$CS2_RUNTIME_BREW_FORMULA via Homebrew"
  HOMEBREW_NO_AUTO_UPDATE=1 brew install "$CS2_RUNTIME_BREW_TAP/$CS2_RUNTIME_BREW_FORMULA"
}

install_manual_pkg() {
  local pkg_path="$CS2_RUNTIME_MANUAL_PKG_PATH"
  [[ -n "$pkg_path" ]] || cs2_die "CS2_RUNTIME_MANUAL_PKG_PATH must point to a .pkg file for the manual_pkg channel"
  [[ -f "$pkg_path" ]] || cs2_die "manual pkg not found: $pkg_path"

  if runtime_is_installed; then
    cs2_log "runtime already installed; skipping"
    return 0
  fi

  cs2_log "installing runtime from pkg: $pkg_path"
  sudo installer -pkg "$pkg_path" -target /
}

install_crossover_local() {
  [[ -x "$CS2_RUNTIME_CROSSOVER_WINE" ]] || cs2_die "CrossOver wine binary not found: $CS2_RUNTIME_CROSSOVER_WINE"
  [[ -x "$CS2_RUNTIME_CROSSOVER_WINESERVER" ]] || cs2_die "CrossOver wineserver binary not found: $CS2_RUNTIME_CROSSOVER_WINESERVER"

  cs2_ensure_dir "$CS2_MAC_RUNTIME_BIN"

  ln -sfn "$CS2_RUNTIME_CROSSOVER_WINE" "$CS2_MAC_RUNTIME_BIN/wine"
  ln -sfn "$CS2_RUNTIME_CROSSOVER_WINESERVER" "$CS2_MAC_RUNTIME_BIN/wineserver"
  cat > "$CS2_MAC_RUNTIME_BIN/wineboot" <<'EOF_WINEBOOT'
#!/usr/bin/env bash
set -euo pipefail
exec wine wineboot "$@"
EOF_WINEBOOT
  chmod +x "$CS2_MAC_RUNTIME_BIN/wineboot"

  cs2_log "installed local runtime shims in $CS2_MAC_RUNTIME_BIN"
}

case "$CS2_RUNTIME_CHANNEL" in
  brew_tap)
    install_brew_tap
    ;;
  manual_pkg)
    install_manual_pkg
    ;;
  crossover_local)
    install_crossover_local
    ;;
  *)
    cs2_die "unsupported runtime channel: $CS2_RUNTIME_CHANNEL"
    ;;
esac

printf '\nRuntime installation step finished. Run scripts/verify-runtime.sh to confirm the binaries and versions.\n'
