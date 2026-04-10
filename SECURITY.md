# Security Policy

CS2-Mac is a local shell-based launcher and migration tool. If you find a
security issue, please report it privately rather than opening a public issue.

## What To Report

Report anything that could expose data, overwrite files unexpectedly, or allow
an attacker to influence the runtime, prefix, Steam session, or migration
paths.

Examples include:

- unsafe path handling
- command injection
- unexpected file replacement
- overly broad log or backup exposure

## How To Report

- Use the repository host's private security advisory channel if it is
  available.
- Otherwise contact the maintainers through the private contact path listed for
  the repository hosting location.

Please include:

- the affected script or workflow
- the exact command you ran
- the macOS version
- whether the issue happens in `--dry-run`, `--verify-only`, or `--apply`
- any short reproduction steps that are safe to share

## What To Expect

We will triage the report as quickly as we can, confirm the impact, and work
with you on a fix before broader disclosure.
