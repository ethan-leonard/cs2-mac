#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template_dir="$repo_root/app-template/CS2.app"
target_dir="${CS2_APP_TARGET:-/Applications/CS2.app}"
template_launcher="$template_dir/Contents/MacOS/cs2-launcher"

if [[ ! -d "$template_dir" ]]; then
  echo "Missing app template directory: $template_dir" >&2
  exit 1
fi

if [[ ! -f "$template_launcher" ]]; then
  echo "Missing template launcher: $template_launcher" >&2
  exit 1
fi

if [[ -e "$target_dir" && ! -d "$target_dir" ]]; then
  echo "Target exists and is not a directory: $target_dir" >&2
  exit 1
fi

mkdir -p "$(dirname "$target_dir")"

staging_dir="$(mktemp -d "${target_dir}.staging.XXXXXX")"
cleanup() {
  rm -rf "$staging_dir"
}
trap cleanup EXIT

cp -R "$template_dir/." "$staging_dir/"

escaped_repo_root="${repo_root//\\/\\\\}"
escaped_repo_root="${escaped_repo_root//&/\\&}"
perl -0pi -e "s|__CS2_MAC_REPO_ROOT__|$escaped_repo_root|g" "$staging_dir/Contents/MacOS/cs2-launcher"
chmod 755 "$staging_dir/Contents/MacOS/cs2-launcher"

if [[ -e "$target_dir" ]]; then
  rm -rf "$target_dir"
fi
mv "$staging_dir" "$target_dir"
trap - EXIT

echo "Installed CS2.app to $target_dir"
