# Migrating from MTGuardian

MTGuardianX replaces the legacy guardian and its Telegram/URL helper scripts.
It does not install MTCore, create profiles, or change trading configuration.
Keep a backup of the old scripts, config, and startup entry before migrating.

## Configuration mapping

Upstream `MT_CORE_DIR`, `MT_CORE_ARGS`, `MT_CORE_SERVER_NAME`, `TG_API_TOKEN`,
and `TG_CHAT_ID` keep their names. Set `MT_CORE_PROFILE` explicitly: the original
upstream guardian discovered MTCore globally and did not enforce a profile.
If the old arguments include `--profile-name`, remove that argument/value and
put the value in `MT_CORE_PROFILE` instead.

Start from `example.conf` and copy your values. Enable `TG_NOTIFICATIONS=1` to
restore Telegram notifications; the new default is disabled. The example also
adds logger, backoff, status and log settings. Use one config per profile.

| Legacy setup | MTGuardianX |
| --- | --- |
| `MTGuardian.settings` loaded next to the script | Explicit `--config /path/profile.conf` |
| Whitespace-separated `MT_CORE_ARGS` string | Still accepted; prefer a Bash array to preserve spaces/empty values |
| `telegram_helper.sh`, `rawurlencode.inc.sh` | Built into the guardian; no helper files needed |
| Startup through supplied `rc.local` | Adapt one systemd instance or your existing startup entry |
| Ad hoc restart loop | Per-profile lock, startup attach, configurable crash backoff |
| Console/Telegram diagnostics | Syslog plus optional console/Telegram; event snapshots and reports |

Configs execute as Bash and must be owned by the running user or root, with no
group/world write permission. Use mode `0600` and let the service account read
them. Telegram-enabled configs cannot be group/world-readable.

## Per-profile handover

1. Install the new executable and prepare a config with the **same existing
   profile**, MTCore directory, account, and desired arguments. Provision writable
   state/log paths as described in the README.
2. Disable the old guardian's autostart entry so it cannot return at the next boot.
   Do not replace the entire host's rc.local file; remove only its guardian entry.
3. Stop the old guardian using its known PID/startup mechanism. Inspect the old
   service's kill behavior first: a systemd unit using the default control-group
   kill mode may also stop MTCore. Avoid process-name-wide kill commands.
4. Confirm only the intended MTCore remains and no old guardian can restart it.
   Legacy MTGuardian does not share the new profile lock. Do not run both guardians
   for one profile.
5. Start the corresponding MTGuardianX instance. With a live matching core it
   attaches; if none is found it launches MTCore. Verify the log identifies the
   expected PID and profile and no second core appeared.
6. Read `--status` and `--dump-report`, then check service and core liveness
   separately. The saved timestamp is the last lifecycle observation, not a
   heartbeat. Leave local restart requests disabled unless intentionally needed.

No live restart is required merely to replace a guardian that can be stopped
without stopping its core. Attachment depends on discoverable profile markers or
Linux command-line matching. When the match is ambiguous, resolve it before
starting another supervisor.

## Rollback

Disable the new autostart instance, stop the new guardian, and verify its process
has exited. The example service leaves MTCore running. Restore the old config and
startup entry only after confirming that guardian's attach/launch behavior will
not create a second MTCore. The two guardians must never supervise the same
profile concurrently. State/event files can be retained as migration evidence.

## Packaging changes

The repository now ships `MTGuardianX`, its tests, config and service examples,
and public documentation. Obsolete legacy scripts and `rc.local` are removed.
The separately supplied `deploy_full.sh` is not included: it encodes a particular
fleet's setup, destructive provisioning, and an external sidecar dependency.
There is no fleet deployment step in this migration.
