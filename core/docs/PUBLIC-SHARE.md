# Offering the share on the internet (tm-remote.stoverparc.org) and on the local network

Prepared 2026-10-18. **Nothing here has been applied.** DNS, the reverse proxy and any exposure to the internet are the owner's
call; this page is the exact change to review.

## What a viewer gets

`core/scripts/share-demo.sh --lan --public https://tm-remote.stoverparc.org` makes two links per share, both shown in the eyes
menu in Quick Settings:

| Link | Address | Who can use it |
| --- | --- | --- |
| Internet | `https://tm-remote.stoverparc.org/v/<key>` | Anyone with the link, from anywhere (through the proxy below). |
| Local network | `http://<this machine's LAN address>:8799/v/<key>` | Anyone on the same network with the link. |

The consent model is unchanged on both: a viewer still needs the key **and** your Allow, nothing is sent before the browser's
picker and your approval, and Stop ends every link. Without `--public` only the local-network link exists.

## The proxy (owner applies; needs sudo on the host that runs Caddy)

The share server runs on this laptop, so the proxy on SER8 forwards to it over Tailscale. **Only the viewer routes are exposed.**
The owner page (`/share`), sign-in (`/auth/*`) and every other API route get a 404 from the proxy, so the internet never sees a login
form or an owner endpoint.

```
tm-remote.stoverparc.org {
    import cockpit_incus_access
    bind 192.168.3.251

    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
        -Server
    }

    @viewer {
        path /v /v/* /v.js /share.css
        path /api/v1/share/view/*
    }
    handle @viewer {
        request_body {
            max_size 64KB
        }
        reverse_proxy 100.115.140.33:8799 {
            flush_interval -1
        }
    }
    handle {
        respond "not found" 404
    }
}
```
(`100.115.140.33` is this laptop's Tailscale address; check it with `tailscale ip -4` before applying. The share server must be
started with `--lan --public https://tm-remote.stoverparc.org`, which also sets `RUPERT_TRUST_PROXY=1` so the viewer's real address,
not the proxy's, is used for rate limits and the 10-minute resume rule.)

DNS: a real **A record** `tm-remote` at Hover pointing at the same address as the other `stoverparc.org` hosts (not a redirect).
Caddy runs with `admin off` on SER8, so applying needs `sudo systemctl restart caddy` (a few seconds of blip for every site).
Rollback: restore the previous Caddyfile and restart; delete the A record.

## Risks to accept knowingly

- **The key is in the path** (`/v/<key>`), so Caddy's access log would record it. Keep access logging off for this site block, or treat links as short-lived.
- **Trust proxy:** with `RUPERT_TRUST_PROXY=1` a LAN client that talks to the share server directly could forge its address in
  `X-Forwarded-For`. That can only affect rate-limit bucketing and the resume rule, and the link key and your Allow are still required.
- **Laptop must be on and on the tailnet** for the internet link to work. If it sleeps, viewers see a bad-gateway page.
- **Bandwidth:** the picture is relayed peer-to-peer where it can be (WebRTC); signalling goes through the proxy. Behind strict NATs a TURN
  server (`RUPERT_SHARE_TURN*`) may be needed; none is configured.
- Not tested: the internet path end to end. Only loopback, LAN and tailnet were exercised.
