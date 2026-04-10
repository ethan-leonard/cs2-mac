#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage: check-prereqs.sh [--help]

Checks the host for the minimum conditions needed to install and run the
CS2 runtime stack on Apple Silicon.

Checks:
  - Apple Silicon architecture
  - Rosetta availability
  - Xcode Command Line Tools
  - Free disk threshold
  - Core command-line tools
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

CS2_RUNTIME_MIN_MACOS="${CS2_RUNTIME_MIN_MACOS:-${CS2_RUNTIME_MIN_MACOS_DEFAULT}}"
CS2_CORE_TOOLS="${CS2_CORE_TOOLS:-${CS2_CORE_TOOLS_DEFAULT}}"
CS2_MIN_FREE_GB="${CS2_MIN_FREE_GB:-${CS2_MIN_FREE_GB_DEFAULT}}"

failures=0

check_ok() {
  printf 'ok: %s\n' "$1"
}

check_fail() {
  printf 'fail: %s\n' "$1" >&2
  failures=$((failures + 1))
}

arch_name="$(uname -m)"
if [[ "$arch_name" == "arm64" ]]; then
  check_ok "architecture is arm64"
else
  check_fail "expected arm64 architecture, found $arch_name"
fi

if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
  check_ok "Rosetta translation works"
else
  check_fail "Rosetta is not installed or cannot translate x86_64 binaries"
fi

if xcode-select -p >/dev/null 2>&1; then
  clt_path="$(xcode-select -p)"
  if [[ -d "$clt_path" ]]; then
    if xcrun --find clang >/dev/null 2>&1; then
      check_ok "Xcode Command Line Tools present at $clt_path"
    else
      check_fail "Xcode Command Line Tools path exists but clang is not reachable via xcrun"
    fi
  else
    check_fail "xcode-select returned a missing path: $clt_path"
  fi
else
  check_fail "Xcode Command Line Tools are not installed"
fi

current_macos="$(sw_vers -productVersion)"
if cs2_version_at_least "$CS2_RUNTIME_MIN_MACOS" "$current_macos"; then
  check_ok "macOS version is $current_macos"
else
  check_fail "macOS $CS2_RUNTIME_MIN_MACOS or newer is recommended, found $current_macos"
fi

free_gb="$(cs2_free_gb_for_path "$HOME")"
if [[ "$free_gb" -ge "$CS2_MIN_FREE_GB" ]]; then
  check_ok "free disk space is $free_gb GB on the home volume"
else
  check_fail "need at least $CS2_MIN_FREE_GB GB free, found $free_gb GB"
fi

for tool in $CS2_CORE_TOOLS; do
  if command -v "$tool" >/dev/null 2>&1; then
    check_ok "tool available: $tool"
  else
    check_fail "missing required tool: $tool"
  fi
done

if (( failures > 0 )); then
  printf '\n%d prerequisite check(s) failed.\n' "$failures" >&2
  exit 1
fi

printf '\nAll prerequisite checks passed.\n'
