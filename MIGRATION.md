# CS2 Migration Guide

This repository keeps the CS2 migration logic intentionally small:

- `scripts/adopt-existing-cs2.sh` moves the game payload.
- `scripts/migrate-steam-session.sh` moves Steam session state.
- Both scripts default to `--dry-run` and require `--apply` before they make changes.

Defaults come from `config/paths.env` and can be overridden by CLI flags.

## Default paths

Source Steam root from the CrossOver bottle:

```text
~/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam
```

Target Steam root in the new prefix:

```text
~/Library/Application Support/CS2-Mac/prefix/drive_c/Program Files (x86)/Steam
```

Backup root:

```text
~/Library/Application Support/CS2-Mac/backups
```

## What gets moved

Game content migration:

- `steamapps/appmanifest_730.acf`
- `steamapps/common/Counter-Strike Global Offensive`
- `steamapps/common/Steamworks Shared`

Steam session migration:

- `config/config.vdf`
- `config/loginusers.vdf`
- `userdata/`

The scripts do not edit `libraryfolders.vdf` because the target Steam root is the new prefix's default Steam library path.

## Safety model

The scripts are designed to avoid destructive behavior:

- Default mode is dry-run.
- Existing target paths are moved into a timestamped backup directory before replacement.
- Every apply run writes a journal so the exact set of moves can be reversed.
- No `rm` or `rm -rf` is used.

If source and target live on different devices, `mv` may degrade to a copy/delete operation. The scripts warn about that so you can decide whether to proceed.

## Recommended workflow

1. Inspect what would happen:

```bash
./scripts/adopt-existing-cs2.sh --dry-run
./scripts/migrate-steam-session.sh --dry-run
```

2. Apply the CS2 payload move:

```bash
./scripts/adopt-existing-cs2.sh --apply
```

3. Apply the Steam session move:

```bash
./scripts/migrate-steam-session.sh --apply
```

4. If something looks wrong, roll back the most recent backup set:

```bash
./scripts/adopt-existing-cs2.sh --rollback
./scripts/migrate-steam-session.sh --rollback
```

You can also point rollback at a specific backup directory:

```bash
./scripts/adopt-existing-cs2.sh --rollback --rollback-dir "$HOME/Library/Application Support/CS2-Mac/backups/adopt-existing-cs2/20260409-120000"
```

## How rollback works

The scripts store a journal next to each timestamped backup set.

- `BACKUP <original> <backup>` means a pre-existing target item was moved aside.
- `MOVE <source> <target>` means the source item was moved into the new prefix.

Rollback processes the journal in reverse order and moves each item back to its prior path.

## Notes

- The migration is move-first, not copy-first.
- The session migration may still require Steam to re-authenticate once in the new prefix.
- The scripts only manage the files listed above. They do not build the prefix, install Steam, or launch the game.
