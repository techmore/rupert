# Screen-share demo: design note

Status: **demo, off by default** (`RUPERT_SHARE=1` turns it on; otherwise the routes do not exist and return 404).
Branch `feature/screen-share-demo`, off `rust-core`. Code: `src/share.rs`, `static/share/*`.
Running it: [SCREEN-SHARE-DEMO.md](SCREEN-SHARE-DEMO.md).

## What it is

A signed-in owner shows their screen live to a friend ("buddy") by sending a short link. View only. The picture goes
**peer to peer over WebRTC**; the Rust service only relays the small signaling messages (SDP and ICE) and keeps the
bookkeeping. No frame ever passes through the server, nothing is recorded, nothing is stored (a restart ends every share).

## Consent model (the part that must not regress)

Sharing needs **three separate yeses**, none of which can be given by the viewer or by the server:

1. **The browser's own capture prompt.** The owner page calls `getDisplayMedia()`. On elementary OS / Pantheon
   (Wayland) this goes through the xdg-desktop-portal and PipeWire picker, which is outside the page's control. If the
   owner cancels, nothing is shared and the server is never told to go live. The server only learns `live` from a
   `POST /share/start` that the page sends *after* the stream exists.
2. **Per-viewer admission.** A buddy who opens the link becomes *pending*. No offer is sent, and the server refuses
   signaling in either direction, until the owner clicks **Allow** for that specific viewer (shown with their IP).
   A leaked link therefore cannot silently attach to a live share. **Deny** and **Remove** are always available.
3. **A link the owner made on purpose**, long-lived by default (24 h, `RUPERT_SHARE_LINK_TTL`), revocable, capped viewers (default 1).

Visible indicators while live: a red sticky banner **"You are sharing your screen with N viewer(s)"** with a **Stop
sharing** button, the tab title `● SHARING — N viewer(s)`, and the browser/portal's own "sharing" indicator (Chromium
and Firefox show one; on Pantheon the portal also shows a panel indicator on recent versions, not verified here).

Ends when any of: owner clicks Stop; the browser's own Stop sharing (track `ended`); the owner page closes or loses its
event stream for more than 15 s; the max duration is reached (default 24 h, `RUPERT_SHARE_MAX_SECS`); the server restarts.
Stopping **kills every link** for that owner, so a re-share needs a fresh link.

## Link lifecycle

| Step | Detail |
| --- | --- |
| Create | `POST /api/v1/share/links` (owner session). 128-bit random, `rshare_` + 22 base64url chars. TTL default 86400 s (`RUPERT_SHARE_LINK_TTL`), clamp 60..`RUPERT_SHARE_LINK_TTL_MAX` (86400). At most 5 active links per owner; 10 creations/min. |
| Store | Only the SHA-256 digest is held (in memory). The secret is shown once in the response and kept by the owner page. It is not in the central audit table either. |
| Carry | Link is `https://host/v/<secret>` (changed from `/v#<secret>`: apps and browsers often drop everything after `#`, which produced "link is incomplete"). The page serves the same HTML for any key, moves the secret into an `Authorization: Bearer` header, keeps it in `sessionStorage` for that tab so a reload works, and scrubs the address bar to `/v`. **Trade-off:** the secret is now part of the request path, so a reverse proxy's access log (Caddy, nginx) would record it; the app's own log records only the route template `/v/{tok}`. Keep proxy logs off for this route, or accept short-lived links. The old `/v#<secret>` form still works. |
| Use | Join needs: link valid and unexpired, owner live, viewer slots free (`RUPERT_SHARE_MAX_VIEWERS`, default 1, max 8; pending viewers count). |
| Expire | Expiry only blocks *new* joins; a viewer the owner already admitted stays until Stop/Remove/time limit. |
| Resume | A viewer the owner approved may rejoin from the same address on the same link for 10 minutes (`RESUME_SECS`) without a new Allow, so locking a phone or switching apps does not force re-approval. Remove, Deny, Stop and revoking the link all end that right. A different address always needs approval. |
| Diagnostics | Both pages report connection state (capture size, frames encoded/sent, ICE state, frames decoded, video size) to `POST /api/v1/share/diag` and `/api/v1/share/view/diag`; the owner reads it in `GET /api/v1/share/status` (`diag`). It holds the last report only, in memory, no addresses beyond what the status already shows. |
| Revoke | `DELETE /api/v1/share/links/{id}`: link dies and its viewers are disconnected at once. |
| Audit | Central `audit` rows: `share_link_create`, `share_link_revoke`, `share_start`, `share_stop` (detail says who/why), `share_viewer_join`, `_admit`, `_deny`, `_kick`. Link ids (`slnk_…`) and viewer ids are logged, never secrets. |
| Logs | The existing access log records the **route template** only (no query, no headers). The viewer id travels in a query string on the viewer event stream, but only the template `/api/v1/share/view/events` is ever logged. |

## Threat model

Protected against (tested unless noted):

- *Stranger finds or guesses a link*: 128-bit secret; failures are budgeted per IP (20/min, then 429); constant
  "invalid or expired link" answer for unknown/expired/revoked.
- *Link leaks to the wrong person*: they only become *pending*; the owner sees an unexpected request and clicks Deny.
  They can still occupy the single viewer slot as a nuisance until denied (60 s pending timeout).
- *Viewer tries to push or control*: viewer messages are limited to `answer` and `ice`; there is no data channel and no
  input path; the offer only ever flows owner → viewer. Payloads are capped at 32 KiB, bodies at 64 KiB.
- *Cross-site request forgery on the owner API*: session cookie is `SameSite=Lax`, and every owner `POST/DELETE`
  also needs a custom `X-Rupert-Share` header (forces a CORS preflight that the server never answers).
- *API tokens*: refused on all owner routes (`403`); sharing needs an interactive session with at least manager role.
- *Another tenant or user*: rooms are keyed by (tenant, user); they cannot see, revoke or signal each other's.
- *Page injection / framing*: static pages are served with a strict CSP (`script-src 'self'`, no inline script),
  `frame-ancestors 'none'`, `no-referrer`, `nosniff`, `no-store`. Pages render server data with `textContent`/escaping.
- *Abuse by volume*: the existing limiter on every route; owner stream cap 3; 64 KiB body limit.

**Not** protected (be honest about these):

- *Anyone who holds a live link and is admitted* sees the whole shared surface. The owner chooses the surface in the
  picker; **prefer sharing one window**. Notifications, other windows' contents and the cursor on that surface are visible.
- *The buddy can record or screenshot* what they see. No technical control prevents that.
- *The IP addresses of both peers are exposed to each other* through ICE candidates in a direct connection (the
  owner already sees the viewer's IP). A TURN relay hides them from each other (the relay sees them).
- *The signaling server can in principle mount a man-in-the-middle*: WebRTC media is DTLS-SRTP encrypted between peers,
  and the fingerprint travels through our server. There is no out-of-band fingerprint check in v1. Fine for a demo
  between friends on an instance you run yourself; not a guarantee against a hostile server operator.
- *Server restart or crash* ends the share (by design); links are gone.
- *Admission is per link click, not per person*: the owner approves an IP and a moment, not an identity.
- *The Google sign-in in front (oauth2-proxy)* only guards `/share`, not the link holder (see the demo README).
- Not built: input/control, audio, recording, TURN credentials per viewer, persistent links, multi-room per user.

## NAT / STUN / TURN

- Default ICE servers: public STUN `stun:stun.l.google.com:19302` (`RUPERT_SHARE_STUN`, comma separated, empty = none).
  STUN only helps peers discover their public address; media still flows peer to peer. Two peers behind ordinary
  home NATs usually connect; symmetric NATs, many mobile carriers and some corporate networks will **not** without TURN.
- **TURN is optional and not needed for the demo.** If a friend cannot connect, run `coturn` (on a host with a public IP
  or a forwarded UDP/TCP 3478 and the relay port range) and set `RUPERT_SHARE_TURN=turn:host:3478`,
  `RUPERT_SHARE_TURN_USER`, `RUPERT_SHARE_TURN_CRED`. Notes:
  - The credential is handed to the owner page and to admitted viewers, so a static credential is a shared secret
    anyone holding a link could use to relay traffic through your coturn. Keep the relay bandwidth-limited
    (`total-quota`, `bps-capacity`) and use `no-multicast-peers`, `denied-peer-ip` for RFC1918 ranges.
  - The better design (not built) is coturn `use-auth-secret` with short-lived HMAC-SHA1 credentials minted per join;
    that needs a SHA-1 HMAC, i.e. one new small crate, which this demo avoided.
  - Relayed video costs relay bandwidth (roughly the stream bitrate, up to 3 Mbit/s here).
- Screen content is sent at ≤ 15 fps (ideal), `contentHint=detail`, sender bitrate capped at 3 Mbit/s. The codec is
  whatever the browsers negotiate (VP8/H.264/VP9/AV1); nothing is forced.

## Protocol (SSE + POST, no WebSocket)

axum is built without the websocket feature, and SSE + POST needs no new dependency. Owner events (cookie auth):
`snapshot`, `viewer_request`, `viewer_admitted`, `viewer_gone`, `signal` (viewer answer/ICE), `stopped`. Viewer events
(bearer link secret): `admitted`, `signal` (owner offer/ICE), `ended {reason}`. The viewer reads its event stream with
`fetch` (EventSource cannot set an Authorization header). A viewer whose event stream drops is removed and must rejoin.

Known limits: the owner stream is a broadcast without replay, so signaling messages sent while the owner's stream is
reconnecting are lost (the next 10 s refresh restores the viewer list, an in-flight handshake would need Remove and rejoin).
Only one process; state is in memory, so it is not horizontally scalable (fine for the single container).

## Verification (what was and was not tested)

See the README. Short version: 10 Rust unit tests on the state machine, 47 black-box HTTP checks, and a 20-check
headless two-browser run in which frames arrive only after consent + Allow and stop on Stop. The native screen picker,
real screen contents, TURN, NAT traversal across the internet, Firefox/Safari, and the Caddy/oauth2 path were **not** tested.
