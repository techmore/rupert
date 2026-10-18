#!/usr/bin/env bash
# One-command launcher for the screen-share demo (see docs/SCREEN-SHARE.md for the design and consent model).
#
#   core/scripts/share-demo.sh                 loopback only: you plus a second browser on THIS machine
#   core/scripts/share-demo.sh --lan           also reachable from other devices on your Wi-Fi/LAN
#   core/scripts/share-demo.sh --tailnet       also reachable from devices on your tailnet
#   options: --port N (default 8799)  --max-viewers N (1..8, default 1)  --keep (keep the data dir on exit)
#
# What it does: builds the release binary if needed, starts the server (NOT in dev mode) with RUPERT_SHARE=1 on a throwaway
# data directory, signs up a throwaway owner with a random password using a one-time signup code (so nobody else can sign up),
# prints the addresses to use, and on Ctrl-C stops the server and deletes the data. Nothing is registered anywhere, no external
# service is contacted except Google's public STUN server that the browsers use to find their own addresses
# (set RUPERT_SHARE_STUN= to disable that).
#
# IMPORTANT: open the OWNER page at http://127.0.0.1:PORT/share on the machine whose screen you share. Browsers only allow
# screen capture on 127.0.0.1/localhost or HTTPS, so opening it through the LAN address will not work. The link you copy from
# it already points at the address your buddy can reach.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8799; MODE=local; MAXV=1; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lan) MODE=lan ;;
    --tailnet) MODE=tailnet ;;
    --port) PORT="${2:?--port needs a number}"; shift ;;
    --max-viewers) MAXV="${2:?--max-viewers needs a number}"; shift ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done
case "$PORT" in ''|*[!0-9]*) echo "--port must be a number" >&2; exit 2 ;; esac
case "$MAXV" in [1-8]) ;; *) echo "--max-viewers must be 1..8" >&2; exit 2 ;; esac
if (ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT\$"); then echo "port $PORT is already in use; pick another with --port" >&2; exit 1; fi

BIN=target/release/rupert-core
if [ ! -x "$BIN" ] || [ -n "$(find src static Cargo.toml Cargo.lock -newer "$BIN" -print -quit 2>/dev/null)" ]; then
  echo "building the release binary (the first time takes about a minute)..."
  RUPERT_GIT_REV="$(git rev-parse --short HEAD 2>/dev/null || echo demo)" cargo build --release >/dev/null
fi

LISTEN=127.0.0.1; PUBLIC=""
case "$MODE" in
  lan)
    IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -n "$IP" ] || { echo "could not find this machine's LAN address" >&2; exit 1; }
    LISTEN=0.0.0.0; PUBLIC="http://$IP:$PORT" ;;
  tailnet)
    IP=$(tailscale ip -4 2>/dev/null | head -1)
    [ -n "$IP" ] || { echo "tailscale is not running or has no IPv4 address" >&2; exit 1; }
    LISTEN=0.0.0.0; PUBLIC="http://$IP:$PORT" ;;
esac

DATA=$(mktemp -d /tmp/rupert-share-demo.XXXXXX); chmod 700 "$DATA"
CODE=$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(18))')
PASS=$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(15))')
EMAIL="demo@rupert.local"
SERVER_PID=""; STATE_PID=""
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/rupert-share"; STATE="$STATE_DIR/state.json"
cleanup() {
  if [ -n "$STATE_PID" ]; then kill "$STATE_PID" 2>/dev/null; wait "$STATE_PID" 2>/dev/null || true; fi
  rm -f "$STATE" "$STATE.tmp" 2>/dev/null || true
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill -TERM "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; fi
  if [ "$KEEP" = 1 ]; then echo "data kept in $DATA"; else rm -rf "$DATA"; fi
  echo; echo "demo stopped; every share and every link has ended."
}
trap cleanup EXIT
trap 'exit 0' INT TERM

env RUPERT_SHARE=1 RUPERT_DATA="$DATA/data" RUPERT_LISTEN="$LISTEN:$PORT" RUPERT_COOKIE_SECURE=0 RUPERT_SCHEDULER=0 \
    RUPERT_SIGNUP_CODE="$CODE" RUPERT_SHARE_MAX_VIEWERS="$MAXV" ${PUBLIC:+RUPERT_SHARE_PUBLIC_URL="$PUBLIC"} \
    "$BIN" >"$DATA/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 60); do curl -fs -m 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; kill -0 "$SERVER_PID" 2>/dev/null || { echo "server failed to start:"; tail -5 "$DATA/server.log"; exit 1; }; sleep 0.25; done
curl -fs -m 5 "http://127.0.0.1:$PORT/auth/signup" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"org_name\":\"Share demo\",\"subdomain\":\"demo\",\"signup_code\":\"$CODE\"}" >/dev/null \
  || { echo "could not create the demo owner"; tail -5 "$DATA/server.log"; exit 1; }
printf 'email: %s\npassword: %s\n' "$EMAIL" "$PASS" > "$DATA/owner.txt"; chmod 600 "$DATA/owner.txt"

# Keep $STATE fresh (live? viewers?) for the menu-bar eyes (mseries/share-eyes-wingpanel). Owner-only file, no secrets in it.
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
(
  JAR="$DATA/state.jar"
  curl -fs -m 5 -c "$JAR" "http://127.0.0.1:$PORT/auth/login" -H 'content-type: application/json' \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" >/dev/null 2>&1 || exit 0
  while kill -0 "$SERVER_PID" 2>/dev/null; do
    curl -fs -m 3 -b "$JAR" "http://127.0.0.1:$PORT/api/v1/share/status" 2>/dev/null | python3 -I -c '
import json,sys,time
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(json.dumps({"live":bool(d.get("live")),"viewers":len(d.get("viewers") or []),"updated":int(time.time())}))' > "$STATE.tmp" \
      && chmod 600 "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
    sleep 2
  done
) &
STATE_PID=$!

cat <<EOF

  Screen-share demo is running (not in dev mode; nothing is recorded or stored; signup is closed to everyone but this script).

  1. On THIS machine, open:   http://127.0.0.1:$PORT/share
     Sign in with:            $EMAIL
                              $PASS
  2. Click "Create link", then "Copy". Send the link to your buddy.${PUBLIC:+
     (Links point at $PUBLIC, the address your buddy can reach.)}
  3. Click "Start sharing" and pick ONE WINDOW in the picker (prefer a window over the whole screen).
  4. Your buddy opens the link and waits. You will see "Someone wants to watch": click Allow (or Deny).
  5. Stop at any time with "Stop sharing", the browser's own stop button, or Ctrl-C here. All links die with it.

  Consent: nothing is sent until you grant the browser's picker AND click Allow for that specific viewer.
EOF
case "$MODE" in
  local) echo "  Reachable only from this machine (second browser/profile). Re-run with --lan or --tailnet for another device." ;;
  lan) echo "  Reachable from devices on this network at $PUBLIC. Anyone there who has your link can ask to watch; you still decide." ;;
  tailnet) echo "  Reachable from devices on your tailnet at $PUBLIC (the server also listens on this machine's other addresses)." ;;
esac
echo "  Server log: $DATA/server.log     Press Ctrl-C to stop."
echo

wait "$SERVER_PID"
