#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: build-apps.sh [--help]

Builds both launcher apps into /Applications:
  - /Applications/CS2.app
  - /Applications/CS2 Setup.app
EOF
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 ]]; then
  echo "error: unexpected argument: $1" >&2
  usage >&2
  exit 2
fi

bash "$script_dir/build-cs2-app.sh"
bash "$script_dir/build-setup-app.sh"

echo "Installed launcher apps to /Applications"
