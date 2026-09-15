# MTGuardianX 5.0.1 successor summary

## Provenance

MTGuardianX v5 consolidates the original Greendq/MTGuardian at commit
`4c746432ac11d4bd9f13990ec0390dc506fdc2e7` and subsequent MTGuardianX revisions.
The original operational flow remains: launch or attach to one profile, restart
crashes, and wait after a clean exit. MTCore itself is supplied separately.

## Included capabilities

- Profile-aware startup preflight and Linux command-line discovery fallback.
- Child exit classification and stale marker cleanup.
- Per-profile locking, including child lock-descriptor cleanup.
- Guardian replacement and TERM handling that leave MTCore alive.
- Configurable restart backoff and opt-in local restart request consumption.
- Trusted Bash configs, permission validation, array arguments, interactive setup.
- Syslog, optional console, asynchronous plain-text Telegram notifications.
- Best-effort lifecycle status snapshots, JSON event history, saved crash log tails.
- Read-only status/report commands with explicit unavailable status when absent.
- JSON escaping for representable control characters in diagnostic log text.

## Changes from 5.0.0 to 5.0.1

The imported status and report commands overwrote saved runtime observations with
fresh CLI defaults. They now read the existing snapshot and never create a health
observation themselves. Regression tests preserve the saved bytes and modification
time and reject fabricated health for missing snapshots. Snapshot timestamps
remain event-driven; the watchdog loop has no new heartbeat behavior.

The supplied JSON helper omitted control characters such as ANSI ESC. It now
escapes all representable ASCII controls, with a report regression test. Bash
cannot preserve NUL bytes, so these reports are text diagnostics, not binary log
archives.

The service example provisions writable runtime/log directories and uses
`KillMode=process` to preserve MTCore when replacing the guardian. Its implications
are documented. The fake-core array-argument fixture now uses temporary state/log
roots consistently.

## Verification

Run the Linux fake-core suite and focused Python tests as shown in README.md.
The suite exercises actual guardian processes with an isolated fake MTCore; it
contains no live deployment or Telegram integration test. Passing it does not
establish every host's systemd policy or prove live trading behavior.

## Repository scope

Legacy guardian/helper/startup files are replaced by the consolidated executable,
examples, tests and migration guide. Fleet-specific deployment automation and
external sidecars are deliberately excluded. No credentials or private operational
configuration are required by the public examples.
