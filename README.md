# CS2-Mac

`cs2-mac` is a local Wine/GPTK wrapper for launching Counter-Strike 2 on Apple
Silicon without relying on CrossOver runtime licensing.

The project is intentionally script-first and auditable:

- pinned runtime install (`brew` tap by default)
- deterministic Wine prefix creation
- move-based CS2/session migration from an existing CrossOver bottle
- safe/perf launch profiles with conservative defaults
- doctor + log bundle tooling for break/fix

## Canonical Config Files

- `config/paths.env`: storage and migration paths
- `config/versions.lock`: runtime channel and pinned defaults
- `config/profile.safe.env`: VAC-conservative launcher defaults
- `config/profile.perf.env`: opt-in tuning profile
- `config/update-policy.env`: launch-time update guard policy

Every script loads these configs so path behavior is consistent.

## Fastest Setup

Run this once for a guided, no-game-launch setup:

```bash
./scripts/setup.sh
```

This runs prereq checks, runtime install/verify, prefix init, migration
dry-runs, and app build steps. It does not launch Steam or CS2.

If you want migration apply included:

```bash
./scripts/setup.sh --with-migration-apply
```

For a macOS app entrypoint:

```bash
./scripts/build-apps.sh
```

Manual app build scripts are also available:

- `./scripts/build-cs2-app.sh`
- `./scripts/build-setup-app.sh`

Then use:

- `/Applications/CS2 Setup.app` for setup/bootstrap
- `/Applications/CS2.app` for launch

## Quick Start (Recommended Order)

1. Validate host prerequisites:

```bash
./scripts/check-prereqs.sh
```

2. Install runtime and verify binaries:

```bash
./scripts/install-runtime.sh
./scripts/verify-runtime.sh
```

3. Initialize prefix layout:

```bash
./scripts/init-prefix.sh
```

4. Dry-run migration first:

```bash
./scripts/adopt-existing-cs2.sh --dry-run
./scripts/migrate-steam-session.sh --dry-run
```

5. Apply migration once dry-run looks correct:

```bash
./scripts/adopt-existing-cs2.sh --apply
./scripts/migrate-steam-session.sh --apply
```

6. Dry-run launcher checks:

```bash
./scripts/launch-steam.sh --dry-run
./scripts/launch-cs2.sh --dry-run
```

If CS2 first-launch gets stuck in Steam on prerequisites, prime redists once:

```bash
./scripts/prime-redists.sh
```

If Steam or Wine leaves stale processes behind for this prefix, use the scoped
cleanup helper or ask doctor to run it before re-checking:

```bash
./scripts/cleanup-runtime.sh
./scripts/doctor.sh --cleanup-runtime
```

7. Initialize update baseline after you verify stability:

```bash
./scripts/update-guard.sh --status
./scripts/update-guard.sh --approve-current
```

After this, launcher runs will block automatically when Steam/CS2/runtime drift
from approved versions until you re-validate (Deathmatch first) and re-approve.

8. Build app wrappers (Spotlight launchers):

```bash
./scripts/build-apps.sh
```

## Launch Profiles

`safe` is the default profile.

Current safe/perf baseline values:

- `WINEMSYNC=1`
- `WINEESYNC=1`
- `DXVK_ASYNC=0`
- `MTL_HUD_ENABLED=0`
- `WINEDEBUG=-all`

Use perf explicitly when testing:

```bash
./scripts/launch-cs2.sh --profile perf --dry-run
```

## Update Guard

`launch-cs2.sh` calls `./scripts/update-guard.sh --check` by default.

Guard behavior:

- detects Steam version, CS2 buildid, and wine version changes
- runs quick safety checks on detected deltas
- blocks launch on unapproved updates by default
- writes a report to:
  `~/Library/Application Support/CS2-Mac/state/update-guard-last-report.txt`
- shows a popup with the remediation path

This is risk-reduction only. It cannot guarantee VAC safety. Treat approval as a
manual gate after real validation in Deathmatch.

## Acceptance Harness

Default test mode is read-only (`--verify-only`).

```bash
./scripts/test-smoke.sh
./scripts/test-migration.sh --verify-only
./scripts/test-launch.sh --verify-only
./scripts/test-update-guard.sh --verify-only
./scripts/test-live-cs2.sh --dry-run
```

Live mode (`--apply`) runs real actions:

```bash
./scripts/test-smoke.sh --apply
./scripts/test-migration.sh --apply
./scripts/test-launch.sh --apply
./scripts/test-update-guard.sh --verify-only
./scripts/test-live-cs2.sh --attempts 3
```

What the harness checks:

- script presence/executable/syntax/help output
- migration dry-run/apply wiring
- launch entrypoint wiring
- no duplicate CS2 payload check after migration apply mode
- repeated CS2 live launch validation with clean teardown and log-based AppID 730 process creation checks

## Public Script Interface

- `scripts/check-prereqs.sh`
- `scripts/install-runtime.sh`
- `scripts/verify-runtime.sh`
- `scripts/init-prefix.sh`
- `scripts/setup.sh`
- `scripts/adopt-existing-cs2.sh`
- `scripts/migrate-steam-session.sh`
- `scripts/launch-steam.sh`
- `scripts/launch-cs2.sh`
- `scripts/cleanup-runtime.sh`
- `scripts/prime-redists.sh`
- `scripts/doctor.sh`
- `scripts/update-guard.sh`
- `scripts/collect-logs.sh`
- `scripts/build-cs2-app.sh`
- `scripts/build-setup-app.sh`
- `scripts/build-apps.sh`
- `scripts/test-smoke.sh`
- `scripts/test-migration.sh`
- `scripts/test-launch.sh`
- `scripts/test-update-guard.sh`
- `scripts/test-live-cs2.sh`

## Troubleshooting

Start here when anything breaks:

```bash
./scripts/doctor.sh
./scripts/collect-logs.sh
```

Then follow `RUNBOOK.md`.
