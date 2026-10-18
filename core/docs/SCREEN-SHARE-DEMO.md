# Screen-share demo: run it, then (later) expose it

Design, consent model and threat model: [SCREEN-SHARE.md](SCREEN-SHARE.md). The feature is **off unless `RUPERT_SHARE=1`**.

## Run it locally (one command)

```bash
core/scripts/share-demo.sh [--lan | --tailnet] [--port N] [--max-viewers N]
```
Builds if needed, starts the server (not in dev mode), creates a throwaway owner with a one-time signup code, prints the login and the address buddies should use, and deletes everything on Ctrl-C. The live-test checklist is [SCREEN-SHARE-TEST-TODAY.md](SCREEN-SHARE-TEST-TODAY.md). The manual way, step by step:

```bash
cd core && cargo build            # or: cargo build --release
RUPERT_SHARE=1 RUPERT_DEV=1 RUPERT_COOKIE_SECURE=0 RUPERT_SCHEDULER=0 RUPERT_DATA=/tmp/rupert-share-demo \
  RUPERT_LISTEN=127.0.0.1:8799 ./target/debug/rupert-core
```

Create an owner account once (dev mode allows signup; the password needs 12+ characters):

```bash
curl -s localhost:8799/auth/signup -H 'content-type: application/json' \
  -d '{"email":"me@example.test","password":"correct-horse-battery","org_name":"Demo","subdomain":"demo"}' >/dev/null
```

1. Owner: open `http://127.0.0.1:8799/share`, sign in, **Create link**, copy it (`/v#rshare_…`).
2. Buddy (another browser/profile, or another machine that can reach the server): open the link. They see "Waiting…".
3. Owner: **Start sharing**, pick a window in the browser/portal picker. The red banner appears.
4. Owner: the buddy shows up as "Someone wants to watch": click **Allow**. The buddy's video starts in about 0.1-0.2 s locally.
5. **Stop sharing** (or the browser's own Stop button, or close the tab) ends it and kills every link.

Knobs (env): `RUPERT_SHARE_MAX_VIEWERS` (1), `RUPERT_SHARE_LINK_TTL_MAX` (86400), `RUPERT_SHARE_MAX_SECS` (7200),
`RUPERT_SHARE_STUN` (Google's public STUN; empty for none), `RUPERT_SHARE_TURN` / `_TURN_USER` / `_TURN_CRED` (optional),
`RUPERT_SHARE_PUBLIC_URL` (a bare `http(s)://host[:port]` origin; links shown on the owner page use it instead of the page's own address, which matters because the owner page must be opened on 127.0.0.1 or HTTPS while buddies need an address they can reach).
Browsers need a secure context for `getDisplayMedia`: `http://127.0.0.1` and `localhost` count; any other host needs HTTPS.

## Tests

```bash
cd core
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test   # 10 share unit tests among the rest
python3 -I tests/share_smoke.py                                                  # 47 HTTP checks (auth, caps, revoke, rate limit, audit, logs)
bun tests/share_browser.mjs                                                      # 20 checks, two headless browsers, no window shown
# same checks through a real network address (a second device's path); MDNS_MASK=1 keeps the browser's default WebRTC privacy:
LISTEN_HOST=0.0.0.0 VIEWER_HOST=<this machine's LAN or tailnet IP> MDNS_MASK=1 bun tests/share_browser.mjs
```

`share_browser.mjs` starts its own throwaway server and two **separate headless Chromium-family browsers** (default
`/opt/brave.com/brave/brave`, override with `BROWSER_BIN`), with fresh profiles; it never touches a running desktop browser.
**The native screen picker cannot be driven headlessly**, so in the owner page only `getDisplayMedia` is replaced by a
stub that stays pending (picker open), rejects (owner denies), or later returns an animated canvas stream (owner grants).
Signaling, consent gates, the WebRTC connection, and video decode are real. It asserts: nothing flows while the picker
is open or after a denial, a pending viewer gets no frames until **Allow**, frames then advance, and after **Stop** (and
after the browser-native stop) frames cease and the old link is refused.

## Exposing it behind https://rrupert.stoverparc.org later (NOT applied; owner approves each step)

Base: [PUBLIC-STEP-RUNBOOK.md](PUBLIC-STEP-RUNBOOK.md) steps must be done first. Then:

1. **Service env** in the `rupert-core` container (`/etc/rupert-core/env`): add `RUPERT_SHARE=1` and `RUPERT_TRUST_PROXY=1`
   (so the per-IP limits see the real client, not Caddy). `systemctl restart rupert-core`. Check
   `curl -s -o /dev/null -w '%{http_code}' http://10.96.131.175:8798/v` returns 200.
2. **Caddy.** The viewer page and its API must be reachable by the buddy **without** Google sign-in (the link secret
   is their credential). In the runbook block, (a) extend the machine matcher and (b) keep SSE uncompressed:

   ```
   @compress not path /api/v1/events /api/v1/share/* /hooks/*
   encode @compress zstd gzip

   @machine path /hooks/* /healthz /api/v1/* /v /v.js /share.css
   ```

   `/share` and `/share.js` (the owner page) deliberately stay in the default `handle`, i.e. **behind Google sign-in**
   (only the owner's email in `rrupert-oauth2-emails.txt`), then the owner signs in to Rupert as usual. Do not add the
   buddy's email to that file; they do not need it. The API under `/api/v1/share/*` is app-authenticated (session or
   link secret) and already covered by `/api/v1/*`; `flush_interval -1` is already set for streaming.
   Apply exactly like the runbook (copy the Caddyfile, `caddy validate`, `systemctl restart caddy`, verify a second site).
3. **Verify** from outside: `curl -sI https://rrupert.stoverparc.org/v` → 200 with CSP; `/share` → 302 to Google;
   `/api/v1/share/status` without a session → 401; a join with a bad secret → 401.
4. **Share**: owner opens `https://rrupert.stoverparc.org/share` (HTTPS satisfies the secure-context rule), creates a link, sends
   `https://rrupert.stoverparc.org/v#rshare_…` in chat. Prefer one window in the picker.
5. **If the buddy cannot connect** (stays on "Connecting…"): that is NAT. Set up coturn (see SCREEN-SHARE.md) and set the
   `RUPERT_SHARE_TURN*` variables; do not open it up beyond that.
6. **Roll back**: remove `RUPERT_SHARE=1` and restart (routes vanish, all shares end); revert the Caddy matcher lines.

Not covered: the Caddy/oauth2 path, real internet NAT traversal and TURN were not tested here.

## Measured (2026-10-18, Asahi aarch64 laptop, loopback, one run each, not a benchmark)

- Release binary idle RSS with `RUPERT_SHARE=1`: about 7 MB (one reading, empty data dir; the service as a whole is ~36 MB RSS under load per the spec).
- Owner clicks Allow to first decoded frame in the viewer: two runs of 5 gave medians of 153 ms and 104 ms (loopback, canvas
  source, no STUN, same machine; says nothing about internet latency, quality, or CPU, which were **not** measured).
- Not run: `tests/adjust_consistency.py` (needs `oha` and a seeded dir; unrelated to this change). `ops_smoke.py` passes 21/21 with a
  binary built with `RUPERT_GIT_REV` set; the 1 failure on my plain debug build is the unset git rev check.
