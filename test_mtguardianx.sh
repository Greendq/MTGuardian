#!/usr/bin/env bash
# Functional tests for MTGuardianX v5.
# The tests create a fake MTCore that writes real sandboxed .cscdat files.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
MTGX="${SCRIPT_DIR}/MTGuardianX"
WORK="$(mktemp -d)"
export MTGX_TMP_DIR="${WORK}/cscdat"
mkdir -p "${MTGX_TMP_DIR}"
STATE_ROOT="${WORK}/run"
LOG_ROOT="${WORK}/log"
FAIL=0
declare -a GUARDIAN_PIDS=()

run_mtgx() {
    bash "${MTGX}" "$@"
}

pass() { printf '  OK   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

pid_in() {
    local file="$1" needle="$2"
    grep -m1 -- "${needle}" "${file}" 2>/dev/null | sed -n 's/.*pid \[\([0-9][0-9]*\)\].*/\1/p'
}

cleanup_test_cscdat() {
    local f
    for f in "${MTGX_TMP_DIR}"/*.cscdat; do
        [[ -f "${f}" ]] || continue
        if grep -q '^PROFILE:Test_Prof_V5$' "${f}" 2>/dev/null; then
            rm -f -- "${f}" 2>/dev/null || true
        fi
    done
}

cleanup() {
    local pid
    if (( ${#GUARDIAN_PIDS[@]} > 0 )); then
        for pid in "${GUARDIAN_PIDS[@]}"; do
            kill -TERM "${pid}" 2>/dev/null || true
        done
        for pid in "${GUARDIAN_PIDS[@]}"; do
            wait "${pid}" 2>/dev/null || true
        done
    fi
    cleanup_test_cscdat
    rm -rf -- "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

cat > "${WORK}/MTCore" <<'EOF'
#!/usr/bin/env bash
set -u

profile=""
if [[ -n "${MTCORE_ARG_DUMP:-}" ]]; then
    : > "${MTCORE_ARG_DUMP}"
    for arg in "$@"; do
        printf '[%s]\n' "${arg}" >> "${MTCORE_ARG_DUMP}"
    done
fi

while (( $# > 0 )); do
    case "$1" in
        --profile-name)
            profile="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

pid=$$
cscdat="${MTGX_TMP_DIR:-/tmp}/${pid}.cscdat"
# MTCORE_NO_CSCDAT=1 simulates a core that left no pid-keyed cscdat the scan can
# match (e.g. a --wait4pid self-relaunch); the guardian must still find it by cmdline.
if [[ -z "${MTCORE_NO_CSCDAT:-}" ]]; then
cat > "${cscdat}" <<CSC
BUILD:0.5.21608
SOURCE:dummy
PROFILE:${profile}
CSC
fi

printf '%s\n' "${pid}:${MTCORE_MODE:-clean}" >> "${MTCORE_START_LOG:-/dev/null}"
[[ -n "${MTCORE_CONSOLE:-}" ]] && { printf 'MTCORE_CONSOLE_OUT\n'; printf 'MTCORE_CONSOLE_ERR\n' >&2; }

case "${MTCORE_MODE:-clean}" in
    clean)
        rm -f -- "${cscdat}"
        exit 0
        ;;
    crash)
        exit 7
        ;;
    segv)
        kill -SEGV "$$"
        sleep 1
        exit 139
        ;;
    stalezero)
        exit 0
        ;;
    runfor)
        sleep "${MTCORE_RUN:-3}"
        rm -f -- "${cscdat}"
        exit 0
        ;;
    hang)
        while :; do sleep 1; done
        ;;
    *)
        exit 99
        ;;
esac
EOF
chmod +x "${WORK}/MTCore"

cat > "${WORK}/test.conf" <<EOF
LOG_TO_CONSOLE=1
LOGGER_TAG='mtgx-v5-test'
MT_CORE_SERVER_NAME='test-host'
MT_CORE_RESTART_DELAY=1
TG_NOTIFICATIONS=0
TG_API_TOKEN=''
TG_CHAT_ID=''
MT_CORE_DIR='${WORK}'
MT_CORE_ARGS=''
MT_CORE_PROFILE='Test_Prof_V5'
MONITOR_POLL_INTERVAL=1
MTGX_STATE_ROOT='${STATE_ROOT}'
MTGX_LOG_ROOT='${LOG_ROOT}'
MTGX_REPORT_LOG_LINES=20
MTGX_ALLOW_REQUEST_RESTART=1
EOF

printf 'Test 1: bash syntax\n'
if bash -n "${MTGX}"; then pass "syntax is valid"; else fail "bash -n failed"; fi

printf 'Test 2: no args usage\n'
out="$(run_mtgx 2>&1)" && rc=0 || rc=$?
if (( rc == 1 )) && grep -q 'Usage:' <<<"${out}"; then pass "usage returned rc=1"; else fail "unexpected rc/output"; fi

printf 'Test 3: version\n'
out="$(run_mtgx --version 2>&1)" && rc=0 || rc=$?
if (( rc == 0 )) && [[ "${out}" == "MTGuardianX 5.0.1" ]]; then pass "version string"; else fail "got ${out}"; fi

printf 'Test 4: bad profile rejected\n'
cp "${WORK}/test.conf" "${WORK}/bad-profile.conf"
perl -pi -e "s/Test_Prof_V5/bad profile/" "${WORK}/bad-profile.conf"
out="$(run_mtgx --config "${WORK}/bad-profile.conf" 2>&1)" && rc=0 || rc=$?
if (( rc == 1 )) && grep -q 'MT_CORE_PROFILE' <<<"${out}"; then pass "profile regex enforced"; else fail "bad profile was not rejected"; fi

printf 'Test 4a: underscore profile accepted\n'
out="$(run_mtgx --config "${WORK}/test.conf" --status 2>&1)" && rc=0 || rc=$?
if (( rc == 0 )) && grep -Eq '"profile":[[:space:]]*"Test_Prof_V5"' <<<"${out}"; then
    pass "underscore profile accepted by status mode"
else
    fail "underscore profile status failed rc=$rc out=$out"
fi

printf 'Test 4b: missing MTCore exits rc=2\n'
cp "${WORK}/test.conf" "${WORK}/missing-core.conf"
perl -pi -e "s|MT_CORE_DIR='\\Q${WORK}\\E'|MT_CORE_DIR='${WORK}/missing'|" "${WORK}/missing-core.conf"
out="$(run_mtgx --config "${WORK}/missing-core.conf" 2>&1)" && rc=0 || rc=$?
if (( rc == 2 )) && grep -Eq 'MT_CORE_DIR|MTCore binary' <<<"${out}"; then pass "missing MTCore returns rc=2"; else fail "missing MTCore rc=$rc out=$out"; fi

printf 'Test 5: clean exit enters monitoring mode\n'
cleanup_test_cscdat
MTCORE_MODE=clean MTCORE_START_LOG="${WORK}/starts-clean.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/clean.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 3
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true
if grep -q 'succesfly started' "${WORK}/clean.log" &&
   grep -q 'did clean exit' "${WORK}/clean.log" &&
   grep -q 'received SIG_TERM' "${WORK}/clean.log"; then
    pass "clean path and signal path logged"
else
    fail "missing clean path log lines"
    sed 's/^/    | /' "${WORK}/clean.log"
fi

printf 'Test 5a: status and event files are written\n'
status_file="${STATE_ROOT}/Test_Prof_V5/status.json"
events_file="${LOG_ROOT}/Test_Prof_V5.events.jsonl"
if [[ -s "${status_file}" ]] &&
   [[ -s "${events_file}" ]] &&
   grep -Eq '"profile":[[:space:]]*"Test_Prof_V5"' "${status_file}" &&
   grep -q '"event":"core_started"' "${events_file}"; then
    pass "status/events files written"
else
    fail "status/events files missing"
    sed 's/^/    | /' "${status_file}" 2>/dev/null || true
    sed 's/^/    | /' "${events_file}" 2>/dev/null || true
fi

printf 'Test 5b: clean-exit message reports real launched PID\n'
start_pid="$(pid_in "${WORK}/clean.log" 'succesfly started')"
exit_pid="$(pid_in "${WORK}/clean.log" 'did clean exit')"
if [[ -n "${start_pid}" && "${start_pid}" == "${exit_pid}" && "${start_pid}" != "0" ]]; then
    pass "clean-exit PID matches started PID (${start_pid})"
else
    fail "PID mismatch: started=${start_pid:-missing} clean=${exit_pid:-missing}"
    sed 's/^/    | /' "${WORK}/clean.log"
fi

printf 'Test 6: crash alerts and restarts\n'
cleanup_test_cscdat
MTCORE_MODE=crash MTCORE_START_LOG="${WORK}/starts-crash.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/crash.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 4
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true
starts="$(wc -l < "${WORK}/starts-crash.log" 2>/dev/null || printf '0')"
if grep -q '!Alert: MTCore pid' "${WORK}/crash.log" && (( starts >= 2 )); then
    pass "crash produced alert and restarted"
else
    fail "crash restart was not observed"
    sed 's/^/    | /' "${WORK}/crash.log"
fi

printf 'Test 6a: crash snapshot and dump report are available\n'
snapshot_file="${LOG_ROOT}/Test_Prof_V5.last-crash.log"
out="$(run_mtgx --config "${WORK}/test.conf" --dump-report 2>&1)" && rc=0 || rc=$?
if (( rc == 0 )) &&
   [[ -s "${snapshot_file}" ]] &&
   grep -q 'crash_class=crash' "${snapshot_file}" &&
   grep -q '"recent_events"' <<<"${out}"; then
    pass "crash snapshot and report emitted"
else
    fail "crash snapshot/report missing rc=$rc out=$out"
    sed 's/^/    | /' "${snapshot_file}" 2>/dev/null || true
fi

printf 'Test 7: SIGSEGV uses Alarm\n'
cleanup_test_cscdat
MTCORE_MODE=segv MTCORE_START_LOG="${WORK}/starts-segv.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/segv.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 4
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true
if grep -q '!Alarm: Possible runtime crash' "${WORK}/segv.log" &&
   grep -q 'SIGFAULT-ed' "${WORK}/segv.log"; then
    pass "SIGSEGV detected"
else
    fail "SIGSEGV alarm missing"
    sed 's/^/    | /' "${WORK}/segv.log"
fi

printf 'Test 8: exit 0 with stale cscdat is treated as crash\n'
cleanup_test_cscdat
MTCORE_MODE=stalezero MTCORE_START_LOG="${WORK}/starts-stalezero.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/stalezero.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 3
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true
if grep -q '!Alert: MTCore pid' "${WORK}/stalezero.log"; then
    pass "stale cscdat overrides rc=0"
else
    fail "stale cscdat did not produce crash alert"
    sed 's/^/    | /' "${WORK}/stalezero.log"
fi

printf 'Test 9: monitoring mode attaches to external MTCore by profile\n'
cleanup_test_cscdat
MTCORE_MODE=clean MTCORE_START_LOG="${WORK}/starts-external-guardian.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/external.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 2
MTCORE_MODE=runfor MTCORE_RUN=3 MTCORE_START_LOG="${WORK}/starts-external-core.log" "${WORK}/MTCore" --profile-name Test_Prof_V5 &
ext=$!
sleep 2
if grep -q "Started monitoring MTCore pid \\[${ext}\\]" "${WORK}/external.log"; then
    pass "attached to external pid ${ext}"
else
    fail "external attach was not observed"
    sed 's/^/    | /' "${WORK}/external.log"
fi
wait "${ext}" 2>/dev/null || true
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true

printf 'Test 9b: monitoring attaches to a cmdline-only core (no cscdat / --wait4pid)\n'
cleanup_test_cscdat
MTCORE_MODE=clean MTCORE_START_LOG="${WORK}/starts-cmdline-guardian.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/cmdline.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 2
# core runs but writes NO cscdat -> only the --profile-name cmdline fallback can find it
MTCORE_MODE=runfor MTCORE_RUN=4 MTCORE_NO_CSCDAT=1 MTCORE_START_LOG="${WORK}/starts-cmdline-core.log" "${WORK}/MTCore" --profile-name Test_Prof_V5 &
ext=$!
sleep 2
if grep -q "Started monitoring MTCore pid \\[${ext}\\]" "${WORK}/cmdline.log"; then
    pass "attached to cmdline-only pid ${ext} with no matchable cscdat"
else
    fail "cmdline fallback attach was not observed"
    sed 's/^/    | /' "${WORK}/cmdline.log"
fi
wait "${ext}" 2>/dev/null || true
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true

printf 'Test 10: duplicate same-profile guardian is blocked\n'
cleanup_test_cscdat
MTCORE_MODE=clean MTCORE_START_LOG="${WORK}/starts-lock.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/lock-first.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 2
out="$(MTCORE_MODE=clean bash "${MTGX}" --config "${WORK}/test.conf" 2>&1)" && rc=0 || rc=$?
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true
if (( rc == 1 )) && grep -q 'profile lock' <<<"${out}"; then
    pass "profile lock prevented duplicate guardian"
else
    fail "duplicate guardian was not blocked"
    printf '    | rc=%s out=%s\n' "${rc}" "${out}"
fi

printf 'Test 11: restart storm throttling\n'
cleanup_test_cscdat
cp "${WORK}/test.conf" "${WORK}/storm.conf"
cat >> "${WORK}/storm.conf" <<'EOF'
MT_CORE_RESTART_DELAY=0
MT_CORE_MAX_RESTARTS_PER_WINDOW=1
MT_CORE_RESTART_WINDOW_SECONDS=60
MT_CORE_MAX_RESTART_DELAY=1
EOF
MTCORE_MODE=crash MTCORE_START_LOG="${WORK}/starts-storm.log" bash "${MTGX}" --config "${WORK}/storm.conf" 2>"${WORK}/storm.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 3
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true
if grep -q 'restart storm detected' "${WORK}/storm.log" &&
   grep -q 'mtguardianx_event=restart_throttle' "${WORK}/storm.log"; then
    pass "restart throttle engaged"
else
    fail "restart throttle was not observed"
    sed 's/^/    | /' "${WORK}/storm.log"
fi

printf 'Test 12: startup preflight attaches before launching\n'
cleanup_test_cscdat
MTCORE_MODE=runfor MTCORE_RUN=5 MTCORE_START_LOG="${WORK}/starts-preflight-external.log" "${WORK}/MTCore" --profile-name Test_Prof_V5 &
ext=$!
sleep 1
MTCORE_MODE=clean MTCORE_START_LOG="${WORK}/starts-preflight-guardian.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/preflight.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 2
if grep -q "Started monitoring MTCore pid \\[${ext}\\]" "${WORK}/preflight.log" &&
   [[ ! -s "${WORK}/starts-preflight-guardian.log" ]]; then
    pass "preflight attached to existing MTCore without launching another"
else
    fail "preflight did not attach cleanly"
    sed 's/^/    | /' "${WORK}/preflight.log"
fi
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true
kill -TERM "${ext}" 2>/dev/null || true
wait "${ext}" 2>/dev/null || true

printf 'Test 13: startup preflight removes stale same-profile cscdat\n'
cleanup_test_cscdat
stale="${MTGX_TMP_DIR}/99999999.cscdat"
cat > "${stale}" <<'EOF'
BUILD:dummy
PROFILE:Test_Prof_V5
EOF
MTCORE_MODE=clean MTCORE_START_LOG="${WORK}/starts-stale-preflight.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/stale-preflight.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 2
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true
if [[ ! -e "${stale}" ]] && grep -q 'mtguardianx_event=stale_cscdat_removed' "${WORK}/stale-preflight.log"; then
    pass "stale same-profile file removed before launch"
else
    fail "stale same-profile file was not removed"
    sed 's/^/    | /' "${WORK}/stale-preflight.log"
fi

printf 'Test 14: MT_CORE_ARGS Bash array preserves spaces\n'
cleanup_test_cscdat
cat > "${WORK}/array.conf" <<EOF
LOG_TO_CONSOLE=1
LOGGER_TAG='mtgx-v5-test'
MT_CORE_SERVER_NAME='test-host'
MT_CORE_RESTART_DELAY=1
TG_NOTIFICATIONS=0
TG_API_TOKEN=''
TG_CHAT_ID=''
MT_CORE_DIR='${WORK}'
MT_CORE_ARGS=(--data-dir '/home/mt service/data' --empty '')
MTGX_STATE_ROOT='${STATE_ROOT}'
MTGX_LOG_ROOT='${LOG_ROOT}'
MT_CORE_PROFILE='Test_Prof_V5'
MONITOR_POLL_INTERVAL=1
EOF
MTCORE_MODE=clean MTCORE_ARG_DUMP="${WORK}/arg-dump.log" bash "${MTGX}" --config "${WORK}/array.conf" 2>"${WORK}/array.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 2
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true
if grep -Fxq '[/home/mt service/data]' "${WORK}/arg-dump.log" &&
   grep -Fxq '[]' "${WORK}/arg-dump.log"; then
    pass "array arguments were passed intact"
else
    fail "array arguments were not preserved"
    sed 's/^/    | /' "${WORK}/arg-dump.log" 2>/dev/null || true
fi

printf 'Test 15: --configure quotes Bash values safely\n'
cleanup_test_cscdat
mkdir -p "${WORK}/configure"
(
    cd "${WORK}/configure" || exit 1
    printf '\n\nBob'\''s server\n\n\n%s\n--data-dir "/home/mt service/data"\nQuoteProf1\nquoted\nn\n' "${WORK}" |
        bash "${MTGX}" --configure >/dev/null
)
if bash -n "${WORK}/configure/quoted.conf"; then
    # shellcheck disable=SC1091
    source "${WORK}/configure/quoted.conf"
    if [[ "${MT_CORE_SERVER_NAME}" == "Bob's server" ]] &&
       [[ "${MT_CORE_ARGS}" == '--data-dir "/home/mt service/data"' ]]; then
        pass "generated config survives quotes and spaces"
    else
        fail "generated config values changed unexpectedly"
    fi
else
    fail "generated config is not valid Bash"
fi

printf 'Test 16: guardian can be replaced while MTCore stays alive\n'
cleanup_test_cscdat
MTCORE_MODE=hang MTCORE_START_LOG="${WORK}/starts-replace.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/replace-first.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 2
core_pid="$(sed -n 's/:hang$//p' "${WORK}/starts-replace.log" | head -1)"
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true
sleep 1
MTCORE_MODE=clean MTCORE_START_LOG="${WORK}/starts-replace-second.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/replace-second.log" &
gx2=$!
GUARDIAN_PIDS+=( "${gx2}" )
sleep 2
kill -TERM "${gx2}" 2>/dev/null || true
wait "${gx2}" 2>/dev/null || true
if [[ -n "${core_pid}" ]] &&
   grep -q "Started monitoring MTCore pid \\[${core_pid}\\]" "${WORK}/replace-second.log"; then
    pass "replacement guardian acquired lock and attached to existing MTCore"
else
    fail "replacement guardian could not attach; lock may be inherited"
    sed 's/^/    | /' "${WORK}/replace-second.log" 2>/dev/null || true
fi
[[ -n "${core_pid}" ]] && kill "${core_pid}" 2>/dev/null || true

printf 'Test 17: SIGTERM does not kill supervised MTCore\n'
cleanup_test_cscdat
MTCORE_MODE=hang MTCORE_START_LOG="${WORK}/starts-sigterm.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/sigterm.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 2
core_pid="$(sed -n 's/:hang$//p' "${WORK}/starts-sigterm.log" | head -1)"
if [[ -z "${core_pid}" ]] || ! kill -0 "${core_pid}" 2>/dev/null; then
    fail "fake MTCore not running before SIGTERM"
    sed 's/^/    | /' "${WORK}/sigterm.log" 2>/dev/null || true
else
    kill -TERM "${gx}" 2>/dev/null || true
    wait "${gx}" 2>/dev/null || true
    sleep 1
    if kill -0 "${core_pid}" 2>/dev/null; then
        pass "MTCore remained alive after guardian SIGTERM"
    else
        fail "MTCore was killed by guardian SIGTERM"
        sed 's/^/    | /' "${WORK}/sigterm.log" 2>/dev/null || true
    fi
fi
[[ -n "${core_pid:-}" ]] && kill "${core_pid}" 2>/dev/null || true

printf 'Test 18: local restart request is consumed when enabled\n'
cleanup_test_cscdat
MTCORE_MODE=hang MTCORE_START_LOG="${WORK}/starts-request-restart.log" bash "${MTGX}" --config "${WORK}/test.conf" 2>"${WORK}/request-restart.log" &
gx=$!
GUARDIAN_PIDS+=( "${gx}" )
sleep 2
out="$(bash "${MTGX}" --config "${WORK}/test.conf" --request-restart "test requested restart" 2>&1)" && rc=0 || rc=$?
sleep 3
kill -TERM "${gx}" 2>/dev/null || true
wait "${gx}" 2>/dev/null || true
starts="$(wc -l < "${WORK}/starts-request-restart.log" 2>/dev/null || printf '0')"
if (( rc == 0 )) &&
   grep -q 'core_requested_restart' "${WORK}/request-restart.log" &&
   (( starts >= 2 )); then
    pass "restart request stopped and relaunched core"
else
    fail "restart request did not relaunch core rc=$rc starts=$starts out=$out"
    sed 's/^/    | /' "${WORK}/request-restart.log" 2>/dev/null || true
fi
sed -n 's/:hang$//p' "${WORK}/starts-request-restart.log" 2>/dev/null | while read -r pid; do
    [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
done

printf 'Test 19: MTCore console output stays out of the systemd journal\n'
for journal in 0 1; do
    cleanup_test_cscdat
    if (( journal == 1 )); then
        JOURNAL_STREAM=8:12345 MTCORE_CONSOLE=1 MTCORE_MODE=clean bash "${MTGX}" --config "${WORK}/test.conf" >"${WORK}/console-${journal}.log" 2>&1 &
    else
        MTCORE_CONSOLE=1 MTCORE_MODE=clean bash "${MTGX}" --config "${WORK}/test.conf" >"${WORK}/console-${journal}.log" 2>&1 &
    fi
    gx=$!
    GUARDIAN_PIDS+=( "${gx}" )
    sleep 3
    kill -TERM "${gx}" 2>/dev/null || true
    wait "${gx}" 2>/dev/null || true
done
if ! grep -q 'MTCORE_CONSOLE_' "${WORK}/console-1.log" &&
   grep -q 'succesfly started' "${WORK}/console-1.log" &&
   grep -q 'MTCORE_CONSOLE_OUT' "${WORK}/console-0.log" &&
   grep -q 'MTCORE_CONSOLE_ERR' "${WORK}/console-0.log"; then
    pass "core output dropped under journal, kept on console"
else
    fail "core console routing wrong"
    sed 's/^/    | /' "${WORK}/console-1.log" "${WORK}/console-0.log" 2>/dev/null || true
fi

printf '\n'
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED\n'
    exit 0
fi

printf '%s TEST(S) FAILED\n' "${FAIL}"
exit 1
