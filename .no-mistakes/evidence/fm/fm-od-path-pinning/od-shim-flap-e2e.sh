#!/usr/bin/env bash
# E2E: replay the 2026-10-23 watcher flap at heartbeat-cycle level.
#
# A desktop-app shim at ~/.local/bin/od shadows /usr/bin/od on the operator's
# PATH. Two consecutive watcher heartbeat cycles run against a state dir of
# captain-relevant status logs:
#   cycle 1 must surface every log once (fresh events);
#   cycle 2 must absorb them (durable dedup markers say already reported).
# With a poisoned signature the marker offset reads 0 forever, so cycle 2
# re-reports the same events - the unbounded flap from the incident report.
set -u

BIN_DIR=$1   # bin/ directory of the firstmate copy under test
LABEL=$2     # human label for the transcript

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-od-flap.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# --- the operator's machine: shim at ~/.local/bin/od ahead of /usr/bin/od ----
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/od" <<'FAKEOD'
#!/usr/bin/env bash
printf 'Usage: od-shim [--port <n>] [--host <addr>]\n'
printf 'A shim must never stand in for the octal-dump tool.\n'
printf 'od-shim: unknown option: %s\n' "${1:-}" >&2
exit 2
FAKEOD
chmod +x "$TMP/fakebin/od"
export PATH="$TMP/fakebin:$PATH"

# --- a home with 5 captain-relevant status logs (production had 17) ----------
STATE="$TMP/state"
mkdir -p "$STATE"
for i in 1 2 3 4 5; do
  printf 'working: probing the fleet\nblocked: waiting on review for task-%s\n' "$i" \
    > "$STATE/task-$i.status"
done

export FM_HOME="$TMP/home"
export FM_STATE_OVERRIDE="$STATE"
mkdir -p "$FM_HOME/config"
. "$BIN_DIR/fm-watch.sh"

echo "=== $LABEL ==="
echo "od resolved from PATH: $(command -v od)"
echo "status logs: $(ls "$STATE"/*.status | wc -l | tr -d ' ')"

run_cycle() {  # <n>
  local n=$1
  # heartbeat_scan_finds_actionable returns 0 when something is actionable
  # (found=0), 1 when the heartbeat is absorbed - same sense as the main loop.
  if heartbeat_scan_finds_actionable; then
    local count
    count=$(printf '%s' "$FM_HEARTBEAT_SURFACE_ENDPOINTS" | grep -c '\.status' || true)
    echo "cycle $n: ACTIONABLE - watcher wakes firstmate for $count status log(s)"
    mark_all_captain_relevant_surfaced >/dev/null 2>&1 || true
    return 1
  fi
  echo "cycle $n: absorbed - no captain-relevant change (0 re-reports)"
  return 0
}

run_cycle 1; C1=$?
run_cycle 2; C2=$?

echo "--- dedup markers written to state ---"
ls -a "$STATE" | grep '^\.hb-surfaced' || echo "(none)"
for m in "$STATE"/.hb-surfaced-*; do
  [ -e "$m" ] || continue
  echo "$(basename "$m") -> $(cat "$m")"
done

if [ "$C1" -eq 1 ] && [ "$C2" -eq 0 ]; then
  echo "VERDICT: flap closed - events surface once, then durably deduped"
  exit 0
fi
echo "VERDICT: FLAP - cycle 2 re-reported the same events (unbounded re-report)"
exit 1
