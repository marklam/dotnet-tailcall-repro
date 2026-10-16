#!/bin/sh
# Runs the repro as many short-lived processes and reports the failure rate.
#
# The fault is concentrated in process warm-up, so it must be run as many short processes:
# a single run only fails about 2.5% of the time. Release never reproduces it, by design --
# there the callee is inlined and no tail call is emitted at all.
#
#   ./run.sh [runs] [parallelism] [Debug|Release]
#   NOTAILCALLS=1 ./run.sh        # the control arm: expect 0 failures
#   TIMEOUT=300 ./run.sh          # per-run cap in seconds; a corrupted run can livelock
#                                 # instead of crashing, spinning at 100% of one core
set -eu

RUNS=${1:-400}
PAR=${2:-8}
CONFIG=${3:-Debug}
TIMEOUT=${TIMEOUT:-300}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "${NOTAILCALLS:-0}" = "1" ]; then
    OUT="$ROOT/bin/notail/$CONFIG/"
    BUILD_ARGS="-p:Tailcalls=false -p:OutputPath=$OUT -p:IntermediateOutputPath=obj/notail/$CONFIG/net10.0/"
    EXEDIR="$OUT"
else
    BUILD_ARGS=""
    EXEDIR="$ROOT/App/bin/$CONFIG/net10.0/"
fi

# EXE=... points at an already-published binary, and skips the build. Debug only: a Release
# build inlines the callee and cannot reproduce.
if [ -n "${EXE:-}" ]; then
    SKIPBUILD=1
    if [ ! -x "$EXE" ]; then echo "No such executable: $EXE" >&2; exit 2; fi
fi

if [ "${SKIPBUILD:-0}" != "1" ]; then
    echo "Building $CONFIG${NOTAILCALLS:+ (Tailcalls=false)}..."
    # shellcheck disable=SC2086
    dotnet build "$ROOT/App/App.fsproj" -c "$CONFIG" $BUILD_ARGS -v minimal | tail -3
fi

if [ -z "${EXE:-}" ]; then
    EXE="$EXEDIR/App.exe"
    [ -x "$EXE" ] || EXE="$EXEDIR/App"
fi
if [ ! -x "$EXE" ]; then echo "Not built: $EXEDIR/App[.exe]" >&2; exit 2; fi

# LOGDIR=... puts the per-run logs somewhere collectable, e.g. a CI artifact.
LOGS=${LOGDIR:-$(mktemp -d)}
mkdir -p "$LOGS"
: > "$LOGS/failures.txt"
echo "Running $RUNS processes, $PAR at a time. Logs: $LOGS"

seq 1 "$RUNS" | xargs -P "$PAR" -I{} sh -c   'timeout -k 10s "$2" "$0" > "$1/{}.out" 2> "$1/{}.err" || echo "FAIL {} exit=$?" >> "$1/failures.txt"'   "$EXE" "$LOGS" "$TIMEOUT"

echo
grep -h "^env " "$LOGS"/*.out 2>/dev/null | head -1
echo "runs=$RUNS failures=$(wc -l < "$LOGS/failures.txt" | tr -d ' ')"
# exit=124 is the timeout killing a livelocked run, which counts as a failure.
grep -c 'exit=124' "$LOGS/failures.txt" 2>/dev/null | sed 's/^/timeouts=/'

# A corrupted process can refuse to die: 0% CPU, and kill denied even with admin rights.
# -k above escalates to SIGKILL, but one wedged in the kernel survives that too.
stray=$(ps -W 2>/dev/null | grep -c "[A]pp\.exe" || true)
if [ "${stray:-0}" != "0" ]; then
    echo "WARNING: $stray process(es) from this run are still alive and would not terminate."
    echo "They are themselves a symptom; the batch result above is still valid."
fi
grep -h "FAIL \|Fatal error\|Internal CLR\|AccessViolation" "$LOGS"/*.out "$LOGS"/*.err 2>/dev/null   | sed 's/row=[0-9]*/row=N/; s/col=[0-9]*/col=N/' | sort | uniq -c | sort -rn | head -5
[ "$(wc -l < "$LOGS/failures.txt" | tr -d ' ')" = "0" ]
