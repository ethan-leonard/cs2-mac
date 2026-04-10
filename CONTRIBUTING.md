# Contributing

Thanks for helping improve CS2-Mac.

This repo is intentionally small and shell-script driven, so the best
contributions keep changes focused, easy to review, and easy to verify.

## Before You Start

- Check whether your change fits the existing script-first workflow.
- Prefer small, targeted edits over broad refactors.
- Keep new text and scripts ASCII unless there is a clear reason not to.

## Working Style

- Match the existing Bash style in the repo.
- Avoid adding new runtime dependencies unless they clearly reduce complexity.
- Update docs when behavior, flags, or paths change.
- Do not break the read-only `--verify-only` paths used by the test harness.

## Local Checks

Run the same lightweight checks the repo uses in CI:

```bash
bash -n scripts/*.sh scripts/lib/*.sh
./scripts/test-smoke.sh --verify-only
./scripts/test-migration.sh --verify-only
./scripts/test-launch.sh --verify-only
```

If your change touches runtime behavior, also run the relevant script in
`--dry-run` or `--apply` mode as appropriate.

## Pull Requests

- Describe the user-facing impact.
- Call out any path, prefix, or migration changes explicitly.
- Mention any manual verification you did beyond the default checks.
- Keep the diff readable. A good PR here is usually one idea at a time.
