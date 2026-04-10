#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage: verify-runtime.sh [--help]

Validates the installed runtime binaries and prints their versions.

Checks:
  - Required binaries are on PATH
  - Installed runtime version metadata is available
  - Optional version commands print successfully when supported
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
CS2_RUNTIME_BREW_FORMULA="${CS2_RUNTIME_BREW_FORMULA:-${CS2_RUNTIME_BREW_FORMULA_DEFAULT}}"
CS2_RUNTIME_REQUIRED_BINARIES="${CS2_RUNTIME_REQUIRED_BINARIES:-${CS2_RUNTIME_REQUIRED_BINARIES_DEFAULT}}"
CS2_RUNTIME_VERSION_COMMANDS="${CS2_RUNTIME_VERSION_COMMANDS:-${CS2_RUNTIME_VERSION_COMMANDS_DEFAULT}}"

printf 'runtime channel: %s\n' "$CS2_RUNTIME_CHANNEL"
printf 'brew tap: %s\n' "$CS2_RUNTIME_BREW_TAP"
printf 'brew formula: %s\n' "$CS2_RUNTIME_BREW_FORMULA"

if command -v brew >/dev/null 2>&1; then
  if brew list --formula --versions "$CS2_RUNTIME_BREW_FORMULA" >/dev/null 2>&1; then
    printf 'brew versions: %s\n' "$(brew list --formula --versions "$CS2_RUNTIME_BREW_FORMULA")"
  else
    cs2_warn "brew formula not detected: $CS2_RUNTIME_BREW_FORMULA"
  fi
else
  cs2_warn "brew is not available on PATH"
fi

for binary in $CS2_RUNTIME_REQUIRED_BINARIES; do
  if command -v "$binary" >/dev/null 2>&1; then
    printf 'binary: %s -> %s\n' "$binary" "$(command -v "$binary")"
  else
    cs2_die "required runtime binary missing from PATH: $binary"
  fi
done

for binary in $CS2_RUNTIME_VERSION_COMMANDS; do
  if command -v "$binary" >/dev/null 2>&1; then
    version_output=""
    if version_output="$($binary --version 2>&1)"; then
      printf '%s version: %s\n' "$binary" "$version_output"
    else
      printf '%s version output: %s\n' "$binary" "$version_output"
    fi
  fi
done

printf '\nRuntime verification complete.\n'
