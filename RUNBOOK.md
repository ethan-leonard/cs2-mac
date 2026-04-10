# CS2-Mac Runbook

This repository contains a small, local wrapper for running CS2 through a
Wine/GPTK stack outside CrossOver. The goal is to keep the setup auditable and
easy to repair when Steam, CS2, or the runtime changes underneath us.

## Quick Triage

When something breaks, do these in order:

1. Run `./scripts/doctor.sh`.
2. Run `./scripts/collect-logs.sh`.
3. Open the generated tarball and read `state/doctor.txt` first.
4. Compare the failure to the recovery path below.
5. If Steam or Wine is wedged, run `./scripts/cleanup-runtime.sh` and retry.

## Known Paths On This Machine

These are the current source locations that matter for migration and recovery:

- Project support root: `~/Library/Application Support/CS2-Mac`
- Target prefix: `~/Library/Application Support/CS2-Mac/prefix`
- Host Steam library: `~/Library/Application Support/Steam`
- Legacy CrossOver Steam bottle: `~/Library/Application Support/CrossOver/Bottles/Steam`

The current host Steam library already contains:

- `steamapps/appmanifest_730.acf`
- `steamapps/common/Counter-Strike Global Offensive`
- `steamapps/libraryfolders.vdf`

The legacy CrossOver bottle still contains the Steam session/config files we may
need for migration:

- `config/config.vdf`
- `config/loginusers.vdf`
- `steamapps/appmanifest_730.acf`

## Recovery Paths

### 1. Runtime binaries are missing or broken

Symptoms:

- `doctor.sh` reports missing `wine`, `wineserver`, or related runtime tools.
- Launch scripts fail before Steam appears.

Recovery:

1. Reinstall the pinned runtime with the project install script.
2. Re-run `./scripts/doctor.sh`.
3. If the version changed unexpectedly, update the pinned version in the
   project config before trying again.

What to include in the bug report:

- The full `doctor.sh` output.
- The runtime version it found.
- Whether Rosetta and Xcode command line tools were installed.

### 2. Prefix structure is missing or malformed

Symptoms:

- `doctor.sh` reports that `prefix/drive_c` or `Program Files (x86)` is missing.
- Steam cannot start inside the prefix.

Recovery:

1. Re-run the prefix initialization step.
2. Confirm the target path is `~/Library/Application Support/CS2-Mac/prefix`.
3. Re-run `./scripts/doctor.sh`.

If the prefix was partially created, delete only the broken prefix directory and
start again. Do not delete the host Steam library unless you intend to redownload
everything.

### 3. Steam.exe is missing inside the prefix

Symptoms:

- `doctor.sh` reports `Steam.exe missing`.
- The wrapper opens but Steam does not launch.

Recovery:

1. Recreate the prefix and bootstrap Steam again.
2. Confirm the expected file exists at:
   `~/Library/Application Support/CS2-Mac/prefix/drive_c/Program Files (x86)/Steam/Steam.exe`
3. If you are trying to migrate from the old CrossOver bottle, make sure the
   Steam session files were copied as well.

### 4. CS2 manifest or content is missing

Symptoms:

- `doctor.sh` reports missing `appmanifest_730.acf`.
- `doctor.sh` reports missing `game/csgo/pak01_dir.vpk`.
- Steam shows CS2 as uninstalled or begins a full redownload.

Recovery:

1. Check the host Steam library first:
   `~/Library/Application Support/Steam/steamapps/appmanifest_730.acf`
   `~/Library/Application Support/Steam/steamapps/common/Counter-Strike Global Offensive`
2. If the files exist there, re-run the CS2 adoption step so the prefix points
   at the existing content instead of a fresh empty install.
3. If the prefix Steam library uses a different path, verify that
   `libraryfolders.vdf` still points at the right Steam root.

The important game content markers are:

- `game/csgo/pak01_dir.vpk`
- `game/bin/win64/csgo.signatures`
- `steamapps/appmanifest_730.acf`

### 5. Login state or session data breaks Steam

Symptoms:

- Steam loops on login.
- Steam asks for 2FA repeatedly.
- Steam starts, but the library appears empty or stale.

Recovery:

1. Back up the prefix Steam `config/` directory first.
2. Re-run the Steam session migration step.
3. If that still fails, do a clean Steam login and let the prefix rebuild the
   session files.

Useful source files from the old CrossOver bottle:

- `config/config.vdf`
- `config/loginusers.vdf`
- `userdata/`

### 6. Steam sees CS2, but the game will not launch

Symptoms:

- Steam opens normally.
- CS2 is listed as installed.
- Launch returns to Steam or closes immediately.

Recovery:

1. Run `./scripts/doctor.sh` and confirm the manifest and content checks pass.
2. Prime CommonRedist run-keys once:
   `./scripts/prime-redists.sh`
3. Re-run the game launch script from Terminal so you get a fresh log.
4. Inspect `collect-logs.sh` output for the newest Steam log files.
5. If you see `Steam Service Error` or a maintenance prompt, treat that as the
   active failure first and retry after Steam service recovers.
6. If the failure started after a Steam or CS2 update, compare the current
   `appmanifest_730.acf` against the previous known-good archive.

Focus on these log files first:

- `bootstrap_log.txt`
- `content_log.txt`
- `steamui.txt`
- `gameprocess_log.txt`
- `compat_log.txt`

### Repeated Live Launch Validation

When you want to verify that Steam can repeatedly hand off AppID 730 to the game
without leaving stale Wine processes behind, use:

```bash
./scripts/test-live-cs2.sh --attempts 3
```

This command:

- runs the normal Steam launch path for each attempt
- waits for Steam/game log evidence that AppID 730 reached process creation
- does not pass on `cs2.exe` alone; it waits for the Steam handoff logs that
  the launch actually surfaced
- tears down the prefix with the scoped cleanup helper between attempts
- times out an attempt if the launch never produces the expected handoff logs

If the logs show `Steam Service Error` or a maintenance prompt, the validation
fails immediately with that cause instead of waiting out the timeout.

Useful options:

- `--dry-run` for a command and help/syntax sanity check without launching Steam
- `--timeout-seconds` to raise or lower the per-attempt watchdog
- `--settle-seconds` to give logs time to flush before scanning

### 7. The display or performance profile looks wrong

Symptoms:

- Output is on the wrong monitor.
- The game is not using the expected 1080p60 baseline.
- Frame pacing suddenly feels worse than before.

Recovery:

1. Confirm the active monitor in `doctor.sh` output.
2. Use the safe profile first, not the perf profile.
3. Make sure the profile still disables the aggressive toggles by default.
4. Re-run the game with a clean Steam launch after changing profiles.

On this machine, the intended baseline is:

- External Dell monitor at `1920x1080 @ 60Hz`

### 8. Update guard blocked launch

Symptoms:

- `launch-cs2.sh` exits before opening Steam/CS2.
- Popup says launch is blocked by update guard.
- Report exists at:
  `~/Library/Application Support/CS2-Mac/state/update-guard-last-report.txt`

Recovery:

1. Review current vs approved versions:
   `./scripts/update-guard.sh --status`
2. Run diagnostics:
   `./scripts/doctor.sh`
   `./scripts/collect-logs.sh`
3. Validate safely in Deathmatch only.
4. If stable, approve the new baseline:
   `./scripts/update-guard.sh --approve-current`

Important:

- The guard reduces risk by blocking unapproved drift.
- It cannot guarantee VAC safety.

## Troubleshooting Workflow

Use this order whenever you are uncertain about the failure:

1. Capture the state with `./scripts/doctor.sh`.
2. Bundle the evidence with `./scripts/collect-logs.sh`.
3. Identify the layer that failed:
   - runtime
   - prefix
   - Steam
   - content
   - login/session
   - display/performance
4. Fix only that layer.
5. Re-run doctor before trying the game again.

## What To Send For Help

If you need a second pair of eyes, send:

- The tar.gz archive from `collect-logs.sh`.
- The exact failure message.
- Whether you were using the safe or perf profile.
- Whether the issue started after a Steam update, CS2 update, or runtime update.
- Whether the game files live in the host Steam library or still in the legacy
  CrossOver bottle.

## Guardrails

- Do not delete the host Steam library unless you are intentionally starting
  over.
- Do not hand-edit manifests unless you are restoring from a known-good backup.
- Keep the safe profile as the default. Only switch to the perf profile when you
  are actively testing.
- If a fix works once and then breaks again after an update, treat the update as
  the root cause until proven otherwise.
