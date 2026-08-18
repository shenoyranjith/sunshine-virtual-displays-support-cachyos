#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(mktemp -d /tmp/vdisplay-runtime-test.XXXXXX)"
OLD_SUNSHINE_PID=""
cleanup() {
    if [ -n "$OLD_SUNSHINE_PID" ]; then
        kill "$OLD_SUNSHINE_PID" 2>/dev/null || true
        wait "$OLD_SUNSHINE_PID" 2>/dev/null || true
    fi
    rm -rf "$ROOT"
}
trap cleanup EXIT
mkdir -p "$ROOT/bin" "$ROOT/state" "$ROOT/run" "$ROOT/home/.config"
TRACE="$ROOT/trace"

cat > "$ROOT/bin/kscreen-doctor" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--json" ] || [ "${1:-}" = "-j" ]; then
    if [ "$(cat "$VD_KSCREEN_STATE")" = "virtual" ]; then
        cat <<'JSON'
{"outputs":[
 {"name":"DP-2","enabled":true,"priority":1,"modes":[{"id":"mode-1","size":{"width":1920,"height":1080},"refreshRate":60},{"id":"mode-2","size":{"width":1280,"height":720},"refreshRate":60}]},
 {"name":"DP-3","enabled":false,"priority":2,"modes":[]}
]}
JSON
    else
        cat <<'JSON'
{"outputs":[
 {"name":"DP-2","enabled":false,"priority":2,"modes":[{"id":"mode-1","size":{"width":1920,"height":1080},"refreshRate":60},{"id":"mode-2","size":{"width":1280,"height":720},"refreshRate":60}]},
 {"name":"DP-3","enabled":true,"priority":1,"modes":[]}
]}
JSON
    fi
    exit 0
fi
printf '%s\n' "$*" >> "$VD_TEST_TRACE"
if [ "${VD_FAIL_VIRTUAL:-0}" = "1" ] && [[ "$*" == *output.DP-2.enable* ]]; then
    exit 42
fi
if [[ "$*" == *output.DP-2.enable* ]]; then printf 'virtual\n' > "$VD_KSCREEN_STATE"; fi
if [[ "$*" == *output.DP-3.enable* ]]; then printf 'physical\n' > "$VD_KSCREEN_STATE"; fi
EOF

cat > "$ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$VD_TEST_TRACE"
exit 0
EOF
chmod +x "$ROOT/bin/systemctl"

for command_name in systemd-run kde-inhibit; do
    cat > "$ROOT/bin/$command_name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$ROOT/bin/$command_name"
done
chmod +x "$ROOT/bin/kscreen-doctor"

cat > "$ROOT/config" <<EOF
VIRT_OUTPUT="DP-2"
PHYS_OUTPUT="DP-3"
PHYS_MODE=""
BACKEND="kscreen"
SINGLE_DISPLAY=1
INHIBIT=1
STATE_DIR="$ROOT/state"
DYNAMIC_EDID=0
EOF

export PATH="$ROOT/bin:$PATH"
export HOME="$ROOT/home"
export XDG_RUNTIME_DIR="$ROOT/run"
export VDISPLAY_CONF="$ROOT/config"
export VD_TEST_TRACE="$TRACE"
export VD_KSCREEN_STATE="$ROOT/kscreen-state"
printf 'physical\n' > "$VD_KSCREEN_STATE"
export SUNSHINE_CLIENT_WIDTH=1920
export SUNSHINE_CLIENT_HEIGHT=1080
export SUNSHINE_CLIENT_FPS=60

fail() { echo "FAIL: $*" >&2; exit 1; }

scripts/vdisplay-up.sh
[ -f "$ROOT/run/vdisplay.flag" ] || fail "stream flag was not created"
grep -Fq 'output.DP-2.enable' "$TRACE" || fail "virtual output was not enabled"
grep -Fq 'output.DP-3.disable' "$TRACE" || fail "physical output was not disabled"

scripts/vdisplay-down.sh
[ ! -e "$ROOT/run/vdisplay.flag" ] || fail "stream flag was not removed"
grep -Fq 'output.DP-3.enable' "$TRACE" || fail "physical output was not restored"
grep -Fq 'output.DP-2.disable' "$TRACE" || fail "virtual output was not disabled"

: > "$TRACE"
if VD_FAIL_VIRTUAL=1 scripts/vdisplay-up.sh; then
    fail "failed virtual activation incorrectly returned success"
fi
[ ! -e "$ROOT/run/vdisplay.flag" ] || fail "failed activation left a stream flag"
grep -Fq 'output.DP-3.enable' "$TRACE" || fail "failed activation did not roll back"
if grep -Fq 'output.DP-3.disable' "$TRACE"; then
    fail "physical output was disabled after virtual activation failed"
fi

# Overlapping prep calls hold two leases; the first undo must not tear down the
# display used by the remaining stream.
: > "$TRACE"
scripts/vdisplay-up.sh
scripts/vdisplay-up.sh
grep -Fq 'count=2' "$ROOT/run/vdisplay.flag" || fail "overlapping stream lease was not counted"
: > "$TRACE"
scripts/vdisplay-down.sh
[ -f "$ROOT/run/vdisplay.flag" ] || fail "first undo removed the remaining lease"
if grep -Fq 'output.DP-3.enable' "$TRACE"; then
    fail "first undo restored the physical output while another lease remained"
fi
scripts/vdisplay-down.sh
[ ! -e "$ROOT/run/vdisplay.flag" ] || fail "final undo left a stream lease"

# A concurrent request for a different compositor mode is rejected before it
# can disturb the active stream.
export SUNSHINE_CLIENT_WIDTH=1920
export SUNSHINE_CLIENT_HEIGHT=1080
scripts/vdisplay-up.sh
: > "$TRACE"
if SUNSHINE_CLIENT_WIDTH=1280 SUNSHINE_CLIENT_HEIGHT=720 scripts/vdisplay-up.sh; then
    fail "conflicting concurrent stream mode was accepted"
fi
grep -Fq 'count=1' "$ROOT/run/vdisplay.flag" || fail "conflicting start changed the lease count"
[ ! -s "$TRACE" ] || fail "conflicting start changed the display layout"
scripts/vdisplay-down.sh

# Simulate a surviving old Sunshine process and invoke UP beneath a different
# Sunshine-named parent, as happens when the daemon restarts before watchdog's
# next poll.
run_as_sunshine() {
    bash -c 'printf sunshine > /proc/self/comm; "$@"; status=$?; :; exit "$status"' bash "$@"
}
bash -c 'printf sunshine > /proc/self/comm; sleep 60 & wait' &
OLD_SUNSHINE_PID=$!

# A lease from the prior Sunshine instance must be treated as a fresh start
# even when the new request resolves to the same compositor mode.
DEAD_SUNSHINE_PID=99999999
printf 'virtual\n' > "$VD_KSCREEN_STATE"
cat > "$ROOT/run/vdisplay.flag" <<EOF
count=1
sunshine_pid=$OLD_SUNSHINE_PID
mode_id=mode-1
EOF
: > "$TRACE"
run_as_sunshine scripts/vdisplay-up.sh
grep -Fq 'count=1' "$ROOT/run/vdisplay.flag" || fail "same-mode restart inherited a stale lease"
grep -Fq 'output.DP-2.enable' "$TRACE" || fail "same-mode restart did not reapply the display"
scripts/vdisplay-down.sh

# The same stale lease must not reject a different requested mode as a live
# concurrent conflict.
printf 'virtual\n' > "$VD_KSCREEN_STATE"
cat > "$ROOT/run/vdisplay.flag" <<EOF
count=1
sunshine_pid=$OLD_SUNSHINE_PID
mode_id=mode-2
EOF
: > "$TRACE"
run_as_sunshine scripts/vdisplay-up.sh
grep -Fq 'count=1' "$ROOT/run/vdisplay.flag" || fail "different-mode restart inherited a stale lease"
grep -Fq 'output.DP-2.enable' "$TRACE" || fail "different-mode restart did not reapply the display"
scripts/vdisplay-down.sh
kill "$OLD_SUNSHINE_PID" 2>/dev/null || true
wait "$OLD_SUNSHINE_PID" 2>/dev/null || true
OLD_SUNSHINE_PID=""

# Watchdog stale-lease cleanup must also stop the independent KDE inhibitor.
cat > "$ROOT/run/vdisplay.flag" <<EOF
count=1
sunshine_pid=$DEAD_SUNSHINE_PID
mode_id=mode-1
EOF
: > "$TRACE"
# shellcheck source=../scripts/monitor-watchdog.sh
. scripts/monitor-watchdog.sh
if stream_active; then
    fail "watchdog treated a dead Sunshine pid as active"
fi
[ ! -e "$ROOT/run/vdisplay.flag" ] || fail "watchdog left the stale stream flag"
grep -Fq 'systemctl --user stop vdisplay-inhibit.service' "$TRACE" || \
    fail "watchdog stale cleanup left the inhibitor running"

# A best-effort dynamic-mode queue failure is reported truthfully without
# rolling back an otherwise successful display switch.
cat >> "$ROOT/config" <<EOF
DYNAMIC_EDID=1
PENDING_FILE="$ROOT/missing/pending"
PENDING_LOCK="$ROOT/missing/lock"
EOF
export SUNSHINE_CLIENT_WIDTH=2560
export SUNSHINE_CLIENT_HEIGHT=1440
: > "$ROOT/state/requests.log"
scripts/vdisplay-up.sh
grep -Fq 'WARN unable to queue' "$ROOT/state/requests.log" || fail "queue failure was logged as success"
scripts/vdisplay-down.sh

echo "runtime tests passed"
