#!/usr/bin/env bash
#
# Launch everything the Flutter app needs locally, in one terminal:
#
#   Auth emulator       :9099
#   Firestore emulator  :9002
#   Storage emulator    :9003
#   Functions emulator  :9001  (Auth/Firestore trigger -> Vapor CloudEvents forwarders)
#   Emulator UI         :4000
#   Vapor backend       :8080  (/api/v1/...)
#
# Usage:
#   scripts/dev-local.sh              # start emulators + backend
#   scripts/dev-local.sh --no-build   # skip forwarders npm install/build
#   scripts/dev-local.sh --help
#
# Ctrl-C stops both. Logs: .local/logs/emulators.log (backend logs go to the terminal).
# Flutter debug builds already point at these ports; no --dart-define needed.

set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIREBASE_DIR="${FIREBASE_DIR:-$BACKEND_DIR/../show-menu-firebase}"
FIREBASE_PROJECT="${FIREBASE_PROJECT:-show-menu-dev}"
PORT="${PORT:-8080}"
LOG_DIR="$BACKEND_DIR/.local/logs"
EMULATOR_LOG="$LOG_DIR/emulators.log"
EMULATOR_TIMEOUT="${EMULATOR_TIMEOUT:-120}"

# host:port pairs the Flutter app expects (must match firebase.vapor.json).
EMULATOR_PORTS=(9099 9002 9003 9001)

BUILD_FORWARDERS=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD_FORWARDERS=0 ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;34m[dev-local]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[dev-local] %s\033[0m\n' "$*" >&2; exit 1; }

# ---- preflight ---------------------------------------------------------------
for tool in firebase node npm swift nc; do
  command -v "$tool" >/dev/null || die "'$tool' not found on PATH"
done
[ -d "$FIREBASE_DIR" ] || die "firebase repo not found at $FIREBASE_DIR (set FIREBASE_DIR)"
FIREBASE_DIR="$(cd "$FIREBASE_DIR" && pwd)"

for p in "${EMULATOR_PORTS[@]}" "$PORT" 4000; do
  if nc -z 127.0.0.1 "$p" 2>/dev/null; then
    die "port $p is already in use (stale emulators? try: lsof -nP -iTCP:$p -sTCP:LISTEN)"
  fi
done

mkdir -p "$LOG_DIR"

# ---- cleanup -----------------------------------------------------------------
EMULATOR_PID=""
cleanup() {
  trap - EXIT INT TERM
  if [ -n "$EMULATOR_PID" ] && kill -0 "$EMULATOR_PID" 2>/dev/null; then
    log "stopping emulators..."
    kill -INT "$EMULATOR_PID" 2>/dev/null || true
    # give the Firebase CLI a few seconds to stop its Java children cleanly
    for _ in $(seq 1 15); do kill -0 "$EMULATOR_PID" 2>/dev/null || break; sleep 1; done
    kill -KILL "$EMULATOR_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ---- emulators ---------------------------------------------------------------
if [ "$BUILD_FORWARDERS" -eq 1 ]; then
  log "building emulator forwarders..."
  npm --prefix "$FIREBASE_DIR/forwarders" install --no-audit --no-fund --silent
  npm --prefix "$FIREBASE_DIR/forwarders" run build --silent
fi

log "starting emulators (log: $EMULATOR_LOG)"
( cd "$FIREBASE_DIR" && exec firebase emulators:start \
    --config firebase.vapor.json \
    --only auth,firestore,storage,functions \
    --project "$FIREBASE_PROJECT" ) >"$EMULATOR_LOG" 2>&1 &
EMULATOR_PID=$!

# Build the backend while the emulators boot (they are independent).
log "building backend..."
( cd "$BACKEND_DIR" && swift build --product Run ) || die "swift build failed"

log "waiting for emulators on ports: ${EMULATOR_PORTS[*]}"
deadline=$((SECONDS + EMULATOR_TIMEOUT))
for p in "${EMULATOR_PORTS[@]}"; do
  until nc -z 127.0.0.1 "$p" 2>/dev/null; do
    kill -0 "$EMULATOR_PID" 2>/dev/null || { tail -n 30 "$EMULATOR_LOG" >&2; die "emulators exited early (see $EMULATOR_LOG)"; }
    [ "$SECONDS" -lt "$deadline" ] || { tail -n 30 "$EMULATOR_LOG" >&2; die "timed out waiting for port $p"; }
    sleep 1
  done
done

cat <<EOF

  Emulators ready.
    Auth       http://127.0.0.1:9099
    Firestore  127.0.0.1:9002
    Storage    127.0.0.1:9003
    UI         http://127.0.0.1:4000
  Backend starting on http://127.0.0.1:$PORT/api  (Ctrl-C stops everything)

EOF

# ---- backend (foreground) ----------------------------------------------------
cd "$BACKEND_DIR"
PORT="$PORT" \
GCP_PROJECT_ID="$FIREBASE_PROJECT" \
FIRESTORE_EMULATOR_HOST=127.0.0.1:9002 \
FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
  swift run Run serve || true   # Ctrl-C ends vapor; EXIT trap tears down emulators
