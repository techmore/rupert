# Screen-share demo: test card for a live run

Design and consent model: [SCREEN-SHARE.md](SCREEN-SHARE.md). Run details: [SCREEN-SHARE-DEMO.md](SCREEN-SHARE-DEMO.md).

## What is already proven (automated, headless) and what only you can prove

| Proven by the test suites | Only a live run can show |
| --- | --- |
| Nothing is sent while the picker is open or after a denial; a viewer gets no frames until the owner clicks **Allow** for that viewer; frames flow after Allow; Stop and the browser's own stop both end it and the old link is refused (20 checks, two real browsers, real WebRTC) | That the **native picker** on Pantheon/Wayland appears and captures the window you choose (headless tests replace only that one function with a canvas) |
| The same 20 checks pass with the viewer reaching the server through the LAN address, with the tailnet address, and with the browser's default WebRTC privacy masking on | That a **physically different device** connects (both test browsers share one machine), and over your Wi-Fi |
| Links carry the secret in the URL fragment, expire, can be revoked, are capped; API tokens cannot share; strangers get 401/403/404 (47 HTTP checks) | Real picture quality, smoothness and CPU use with real screen content, which were never measured |
| Allow to first frame: median 105-156 ms over five rounds in each network mode (loopback, same machine) | Latency across the internet |

Environment facts checked on this machine: Wayland session (Pantheon), `xdg-desktop-portal` plus the pantheon, gnome and gtk backends running, PipeWire and WirePlumber active, the portal reports **ScreenCast version 5** with monitor, window and virtual sources, and your Brave 155 runs with `--ozone-platform=wayland`. The picker itself was not opened.

## Run it

```bash
core/scripts/share-demo.sh --lan        # reachable from other devices on this network
core/scripts/share-demo.sh --tailnet    # reachable from devices on your tailnet
core/scripts/share-demo.sh              # this machine only (second browser profile)
```
It prints a throwaway login and the exact address buddies should use. **Open the owner page at `http://127.0.0.1:8799/share` on the machine whose
screen you share** (browsers only allow capture on 127.0.0.1/localhost or HTTPS). Ctrl-C ends every share and deletes all demo data.

## Steps

**A. Same machine, second browser (5 minutes).**
1. Start the launcher. In your normal Brave open the owner page, sign in with the printed login, click **Create link**, **Copy**.
2. Open a *private window* or another browser profile, paste the link. It should say it is waiting for the host.
3. In the owner page click **Start sharing**. The portal picker appears: choose **one window**. A red banner appears: "You are sharing your screen with 0 viewers".
4. The second window asks to be admitted: the owner page shows "Someone wants to watch" with an address. Click **Allow**. Video should start within about a second.
5. Click **Stop sharing**. The viewer must go dead and the link must stop working.

**B. A second device on the same network (the real test).** Run the launcher with `--lan` (or `--tailnet`), repeat the steps with the link sent to a phone or
another computer on the same Wi-Fi/tailnet. The link already points at the right address. If the owner page is opened through the LAN address instead of
127.0.0.1, screen capture will be refused by the browser; that is expected.

**C. A buddy who is not on your network.** Needs one of these; I have not done any of them and each needs your approval:
- *Tailscale Funnel* (a temporary public https address for the demo only): `tailscale funnel 8799` plus `RUPERT_SHARE_PUBLIC_URL=https://<your-node>.<tailnet>.ts.net`.
  Needs Funnel enabled in your tailnet policy. While it runs, the viewer page and the sign-in form are reachable by anyone with the address; signup is closed and sharing
  still needs your two yeses. HTTPS makes the owner page a secure context too.
- *`https://rrupert.stoverparc.org`*, after the runbook steps (DNS record, Google client secret, Caddy with sudo) and the extra Caddy lines in SCREEN-SHARE-DEMO.md.
- If a buddy stays on "Connecting...", that is NAT: use the same tailnet or set up `coturn` (SCREEN-SHARE.md).

## Write down (so the next change is based on facts)

| Question | Result |
| --- | --- |
| Did the picker appear? Which source types did it offer (screen / window)? | |
| Did the banner and tab title show while sharing? Did Pantheon/Brave show its own "sharing" indicator? | |
| Time from clicking Allow to first picture (feel, or stopwatch) | |
| Picture quality when scrolling / typing / video; frame rate feel | |
| Connected on LAN? on tailnet? Needed STUN/TURN? Any "Connecting..." hang? | |
| CPU of the sharing Brave while sharing (top / system monitor) | |
| Did Stop kill the viewer within a second? Did the old link stop working? | |
| Anything surprising about consent (viewer seen without asking, something shown that should not be) | |

## If something fails

| Symptom | Likely cause and next step |
| --- | --- |
| Owner page says capture is unavailable or the picker never opens | Not a secure context (opened via the LAN address instead of 127.0.0.1), or the portal is not answering: `systemctl --user status xdg-desktop-portal xdg-desktop-portal-pantheon`; try running Brave with `--enable-features=WebRTCPipeWireCapturer` |
| Picker opens but the viewer sees black | Wayland capture quirk: share a different source; check the server log path printed by the launcher |
| Link starts with `http://127.0.0.1` | You started without `--lan`/`--tailnet`; restart with the option |
| Buddy stays on "Connecting..." | NAT or mDNS: try `--tailnet`, same Wi-Fi, or coturn |
| "Port in use" | `--port 8800` |

## Safety while testing

Share one **window**, not the whole screen. A viewer sees everything on that surface, can record it, and learns your IP address (and you learn theirs). Deny any request
you do not recognise; **Remove** and **Stop sharing** are always one click. Nothing is recorded or stored by the server, and Ctrl-C deletes the demo's data.
