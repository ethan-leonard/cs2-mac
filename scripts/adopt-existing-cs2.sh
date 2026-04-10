#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/common.sh"
cs2_load_paths

script_name="$(basename "$0")"
script_slug="${script_name%.sh}"

default_source_steam_root="$CS2_CROSSOVER_STEAM_ROOT"
default_target_steam_root="$CS2_MAC_STEAM_ROOT"
default_backup_root="$CS2_MAC_ROOT/backups"

source_steam_root="$default_source_steam_root"
target_steam_root="$default_target_steam_root"
backup_root="$default_backup_root"
mode="dry-run"
rollback_dir=""

items=(
  "steamapps/appmanifest_730.acf"
  "steamapps/common/Counter-Strike Global Offensive"
  "steamapps/common/Steamworks Shared"
)

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  adopt-existing-cs2.sh [--dry-run|--apply] [--rollback]
                        [--source-steam-root PATH]
                        [--target-steam-root PATH]
                        [--backup-root PATH]
                        [--rollback-dir PATH]

What it does:
  - Moves the CS2 appmanifest, Counter-Strike Global Offensive folder, and Steamworks Shared
    out of the CrossOver Steam bottle and into the new prefix Steam root.
  - Backups any existing target paths into a timestamped backup directory before replacing them.
  - Records a journal so the last run can be rolled back.

Defaults:
  - Source Steam root:
      ~/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam
  - Target Steam root:
      ~/Library/Application Support/CS2-Mac/prefix/drive_c/Program Files (x86)/Steam
  - Backup root:
      ~/Library/Application Support/CS2-Mac/backups

Safety:
  - Default mode is --dry-run.
  - No delete operations are used.
  - Rollback restores the latest backup set unless --rollback-dir is provided.

Examples:
  adopt-existing-cs2.sh --dry-run
  adopt-existing-cs2.sh --apply
  adopt-existing-cs2.sh --rollback
  adopt-existing-cs2.sh --apply --source-steam-root "$HOME/Some/Bottle/Steam"
EOF
}

ensure_parent_dir() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
}

print_action() {
  local kind="$1"
  local from="$2"
  local to="$3"
  printf '%s %s -> %s\n' "$kind" "$from" "$to" >&2
}

rollback_journal() {
  local journal="$1"
  [[ -f "$journal" ]] || die "rollback journal not found: $journal"

  log "rolling back from $journal"
  awk 'NF { lines[++n] = $0 } END { for (i = n; i >= 1; i--) print lines[i] }' "$journal" |
    while IFS=$'\t' read -r action from to; do
      [[ -n "${action:-}" ]] || continue
      case "$action" in
        BACKUP|MOVE)
          if [[ -e "$to" ]]; then
            ensure_parent_dir "$from"
            mv "$to" "$from"
            log "restored: $to -> $from"
          else
            log "skipped missing rollback source: $to"
          fi
          ;;
        *)
          die "unknown journal action: $action"
          ;;
      esac
    done
}

latest_backup_dir() {
  local base="$backup_root/$script_slug"
  [[ -d "$base" ]] || return 1
  ls -1dt "$base"/* 2>/dev/null | head -n 1
}

backup_existing_target() {
  local target_path="$1"
  local backup_path="$2"
  local journal="$3"

  if [[ -e "$target_path" ]]; then
    if [[ "$mode" == "dry-run" ]]; then
      print_action "backup" "$target_path" "$backup_path"
    else
      ensure_parent_dir "$backup_path"
      mv "$target_path" "$backup_path"
      printf 'BACKUP\t%s\t%s\n' "$target_path" "$backup_path" >> "$journal"
      log "backed up: $target_path -> $backup_path"
    fi
  fi
}

move_source_into_place() {
  local source_path="$1"
  local target_path="$2"
  local journal="$3"

  if [[ -e "$source_path" ]]; then
    if [[ "$mode" == "dry-run" ]]; then
      print_action "move" "$source_path" "$target_path"
    else
      ensure_parent_dir "$target_path"
      mv "$source_path" "$target_path"
      printf 'MOVE\t%s\t%s\n' "$source_path" "$target_path" >> "$journal"
      log "moved: $source_path -> $target_path"
    fi
  fi
}

run_migration() {
  local run_root="$backup_root/$script_slug/$(date +%Y%m%d-%H%M%S)"
  local journal="$run_root/journal.tsv"
  local source_has_any=0
  local target_has_any=0
  local source_device=""
  local target_device=""

  if [[ -e "$source_steam_root" ]]; then
    source_device="$(stat -f '%d' "$source_steam_root")"
  fi
  if [[ -e "$target_steam_root" ]]; then
    target_device="$(stat -f '%d' "$target_steam_root")"
  fi

  if [[ -n "$source_device" && -n "$target_device" && "$source_device" != "$target_device" ]]; then
    log "warning: source and target live on different devices; mv may fall back to copy/delete"
  fi

  if [[ "$mode" == "apply" ]]; then
    mkdir -p "$run_root"
    : > "$journal"
    {
      printf 'script=%s\n' "$script_name"
      printf 'source_steam_root=%s\n' "$source_steam_root"
      printf 'target_steam_root=%s\n' "$target_steam_root"
      printf 'mode=%s\n' "$mode"
    } > "$run_root/meta.txt"
    log "backup set: $run_root"
  else
    log "dry-run plan would use backup set: $run_root"
  fi

  if [[ "$mode" == "apply" ]]; then
    trap 'status=$?; trap - ERR INT TERM; log "error encountered, attempting rollback"; rollback_journal "$journal" || true; exit "$status"' ERR INT TERM
  fi

  for relative in "${items[@]}"; do
    source_path="$source_steam_root/$relative"
    target_path="$target_steam_root/$relative"
    backup_path="$run_root/$relative"

    if [[ -e "$source_path" ]]; then
      source_has_any=1
      [[ -e "$target_path" ]] && target_has_any=1
      backup_existing_target "$target_path" "$backup_path" "$journal"
      move_source_into_place "$source_path" "$target_path" "$journal"
    elif [[ -e "$target_path" ]]; then
      target_has_any=1
      log "already present: $target_path"
    fi
  done

  if [[ "$source_has_any" -eq 0 && "$target_has_any" -eq 0 ]]; then
    die "no CS2 migration artifacts were found in either source or target Steam roots"
  fi

  if [[ "$mode" == "dry-run" ]]; then
    log "dry-run complete; rerun with --apply to perform the moves"
  else
    log "migration complete; rollback journal: $journal"
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run|-n)
        mode="dry-run"
        ;;
      --apply|-y)
        mode="apply"
        ;;
      --rollback)
        mode="rollback"
        ;;
      --source-steam-root)
        [[ $# -ge 2 ]] || die "--source-steam-root requires a path"
        source_steam_root="$2"
        shift
        ;;
      --target-steam-root)
        [[ $# -ge 2 ]] || die "--target-steam-root requires a path"
        target_steam_root="$2"
        shift
        ;;
      --backup-root)
        [[ $# -ge 2 ]] || die "--backup-root requires a path"
        backup_root="$2"
        shift
        ;;
      --rollback-dir)
        [[ $# -ge 2 ]] || die "--rollback-dir requires a path"
        rollback_dir="$2"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done

  case "$mode" in
    dry-run|apply|rollback) ;;
    *)
      die "invalid mode: $mode"
      ;;
  esac

  if [[ "$mode" == "rollback" ]]; then
    if [[ -z "$rollback_dir" ]]; then
      if ! rollback_dir="$(latest_backup_dir)"; then
        die "no backup sets found under $backup_root/$script_slug"
      fi
    fi
    rollback_journal "$rollback_dir/journal.tsv"
    exit 0
  fi

  run_migration
}

main "$@"
