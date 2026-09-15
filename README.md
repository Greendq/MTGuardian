# MTGuardianX

Version 5.0.1 fixes saved-status clobbering and diagnostic JSON escaping in 5.0.0.

A Bash launcher and watchdog for one MoonTrader MTCore profile. MTGuardianX is
the consolidated successor to [Greendq/MTGuardian](https://github.com/Greendq/MTGuardian),
based on upstream commit `4c746432ac11d4bd9f13990ec0390dc506fdc2e7`.

It attaches to an existing core for the configured profile or launches one,
restarts crashes with bounded backoff, and waits for an external restart after a
clean exit. Notifications go to syslog, with optional console and Telegram output.
There is no fleet controller, trading strategy, or MTCore binary in this repository.

## Requirements

- Linux with Bash, `/proc`, and standard tools from coreutils, findutils, awk,
  grep, and procps (`ps`). `flock` from util-linux is recommended.
- An installed, executable MTCore and an existing profile, accessible to the
  account running the guardian.
- `curl` only for Telegram; `screen` only for optional legacy rc.local setup.
- Perl for the fake-core suite and Python 3 for the focused JSON tests.

## Install and configure

The examples use an existing `mt-service` account and `/opt/mtcore/MTCore`.
Adapt the paths and account to your installation. For an existing guardian,
follow [MIGRATION.md](MIGRATION.md) first.

```bash
sudo install -m 0755 MTGuardianX /usr/local/bin/MTGuardianX
sudo install -d -m 0750 -o mt-service -g mt-service /etc/mtguardianx
sudo install -m 0600 -o mt-service -g mt-service example.conf /etc/mtguardianx/Demo_Profile.conf
```

Edit `Demo_Profile.conf`: set `MT_CORE_DIR`, `MT_CORE_PROFILE`, and the server
label. Use a Bash array for extra arguments, especially values with spaces:

```bash
MT_CORE_DIR=/opt/mtcore
MT_CORE_PROFILE=Demo_Profile
MT_CORE_ARGS=(--no-update --data-dir '/home/mt-service/core data')
```

The guardian adds `--profile-name`; do not include it in extra arguments.
Profiles must match `^[A-Za-z0-9_][A-Za-z0-9_.-]*$`.
Configs are sourced as Bash, so use only trusted, operator-owned files.
Group/world-writable configs are rejected; Telegram configs must also be
unreadable by group/other. Mode `0600` works for both.

An interactive configuration helper is available with `MTGuardianX --configure`.
Its legacy argument string splits on whitespace; convert it to an array if an
argument contains spaces. It can offer rc.local integration when `screen` exists.
Choose one startup mechanism per profile.

### systemd

The template requires systemd 235 or newer.

```bash
sudo install -m 0644 mtguardianx@.service.example /etc/systemd/system/mtguardianx@.service
sudo systemctl daemon-reload
sudo systemctl enable --now mtguardianx@Demo_Profile.service
sudo systemctl status mtguardianx@Demo_Profile.service
```

The template provisions writable state and log directories for `mt-service`.
Each instance name must match `MT_CORE_PROFILE` in its config. If you change
state/log roots, update the unit's directory settings or provision those paths
separately. Keep the default shared `/tmp` view: MTCore discovery uses its
`/tmp/<pid>.cscdat` files.

`KillMode=process` deliberately sends service stop/restart signals only to the
guardian. **Stopping this service leaves MTCore running.** A replacement guardian
attaches to the surviving process. Remaining MTCore and notification children
are outside the service's normal stop cleanup; shut down MTCore separately when
that is your intent. System shutdown can still terminate it. The template is an
example, not a full service isolation policy. See the upstream
[process kill semantics](https://github.com/systemd/systemd/blob/main/man/systemd.kill.xml)
and [directory provisioning settings](https://github.com/systemd/systemd/blob/main/man/systemd.exec.xml).

### Foreground

Without systemd, provision directories before running as `mt-service`:

```bash
sudo install -d -m 0750 -o mt-service -g mt-service /run/mtguardianx /var/log/mtguardianx
sudo -u mt-service /usr/local/bin/MTGuardianX --config /etc/mtguardianx/Demo_Profile.conf
```

`/run` is temporary storage and must be provisioned after each boot. Alternatively,
set both roots to persistent directories writable by the guardian account.

## Lifecycle behavior

| Observation | Action |
| --- | --- |
| Existing same-profile MTCore at startup | Attach without launching a second core |
| Child exits `0` and removes its `.cscdat` | Wait for an external MTCore start |
| Child exits nonzero or leaves stale `.cscdat` | Alert, clean up stale marker, restart |
| Child exit `139` | Report possible SIGSEGV, restart |
| Attached process disappears with stale `.cscdat` | Treat as crash, restart |
| Attached process disappears without `.cscdat` | Treat as clean, wait |
| Guardian receives TERM/INT | Exit without killing MTCore |

A command-line fallback finds a running `MTCore --profile-name <profile>` when
no matching `.cscdat` exists, including self-relaunch scenarios. External process
exit codes are unavailable, so SIGSEGV classification applies only to children
launched by this guardian. Exit `139` is a possible signal indicator, not proof
of the underlying cause.

One guardian locks each profile. On systems without `flock`, an atomic directory
lock is used; an abrupt kill can leave a stale directory requiring manual removal
after verifying no guardian remains. Use one account and shared lock directory
for guardians on a host.

## Status and reports

```bash
MTGuardianX --config /etc/mtguardianx/Demo_Profile.conf --status
MTGuardianX --config /etc/mtguardianx/Demo_Profile.conf --dump-report
```

Both commands read the saved guardian snapshot without modifying it. With no
readable snapshot they return `status_unavailable: true` and `state: unavailable`;
no process health is inferred. A report embeds this object under `status`.
A valid config and installed MTCore are still required by CLI validation.

The snapshot's `ts`/`epoch` record its **last lifecycle observation**, not a
heartbeat. Process state, RSS, threads, file descriptors, age, and counters reflect
that moment. A healthy long-running core can retain an old timestamp; a dead
guardian can leave a snapshot saying `running`. Check process/service liveness
separately. The report's top-level `ts` is report generation time, not snapshot
freshness. Reporting does not change the watchdog polling loop.

Default files:

- `/run/mtguardianx/<profile>/status.json`: best-effort lifecycle snapshot.
- `/var/log/mtguardianx/<profile>.events.jsonl`: lifecycle event history.
- `/var/log/mtguardianx/<profile>.last-crash.log`: most recent crash log snapshot.

Reports include recent events and the saved crash snapshot. Crash collection
scans configured and default log globs; shared directories can include other
profiles' logs. `MTGX_REPORT_LOG_LINES` bounds lines per file, not total bytes.
Reports can contain operational data: review before sharing. Log retention and
rotation are managed by the operator; these files are not automatically rotated.
Status/log write failures are best-effort and do not prevent core supervision.

### Optional restart requests

```bash
MTGuardianX --config /etc/mtguardianx/Demo_Profile.conf --request-restart 'operator maintenance'
```

This writes a local request file and returns once queued; success does not mean a
restart completed. The guardian consumes it on a polling cycle only when
`MTGX_ALLOW_REQUEST_RESTART=1`; otherwise it logs and removes the request.
Requests are disabled by default and require write access to the profile state
directory. An accepted request sends TERM to MTCore and waits for exit before
relaunching. There is no forced-kill deadline if MTCore ignores TERM. This action
can interrupt trading and is separate from replacing the guardian itself.

## Tests

Run on an isolated Linux development host or container:

```bash
bash -n MTGuardianX
bash -n test_mtguardianx.sh
bash test_mtguardianx.sh
python3 test_status.py
```

The suite generates a fake MTCore and temporary config, marker, state and log
files. It covers clean exit, crashes, possible SIGSEGV, external and command-line
attach, profile locking, backoff, argument preservation, guardian replacement,
and restart requests. Focused tests verify saved snapshot bytes/timestamps remain
unchanged, missing snapshots stay unavailable, and control characters in logs
produce valid JSON. Tests do not require a real MTCore or Telegram credentials.

See [SUMMARY.md](SUMMARY.md) for provenance and scope.
