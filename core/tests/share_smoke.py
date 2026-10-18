#!/usr/bin/env python3
"""Black-box test of the screen-share signaling plane. Starts its own servers on temp data dirs.
Usage: python3 -I tests/share_smoke.py [path-to-binary]"""
import http.client, json, os, sqlite3, subprocess, sys, tempfile, time

BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "../target/debug/rupert-core")
PORT = 8793
fails, total = [], 0

def check(name, got, want):
    global total
    total += 1
    if got != want: fails.append(f"{name}: got {got!r}, want {want!r}")

def start(port, extra, log=None):
    data = tempfile.mkdtemp(prefix="rupert-share-")
    env = dict(os.environ, RUPERT_DATA=data, RUPERT_LISTEN=f"127.0.0.1:{port}", RUPERT_COOKIE_SECURE="0",
               RUPERT_BASE_DOMAIN="rupert.test", RUPERT_SIGNUP="open", RUPERT_SCHEDULER="0", **extra)
    p = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=log or subprocess.DEVNULL)
    time.sleep(1)
    return p, data

def call(port, method, path, body=None, hdrs=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    h = {"content-type": "application/json"}; h.update(hdrs or {})
    c.request(method, path, body=json.dumps(body) if body is not None else None, headers=h)
    r = c.getresponse(); raw = r.read(); c.close()
    try: return r.status, json.loads(raw), r.headers
    except Exception: return r.status, raw, r.headers

def sse(port, path, hdrs):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request("GET", path, headers=hdrs); r = c.getresponse()
    return c, r

def events(r, want, limit=10):
    """Read SSE events until `want` (event name) arrives or the stream ends. Returns the list of (event, data)."""
    out, ev = [], None
    while len(out) < limit:
        ln = r.fp.readline().decode()
        if not ln: break
        ln = ln.strip()
        if ln.startswith("event:"): ev = ln[6:].strip()
        elif ln.startswith("data:"):
            out.append((ev, json.loads(ln[5:])))
            if ev == want: break
    return out

PW = "correct-horse-battery"
logf = tempfile.NamedTemporaryFile("w+", delete=False)
# --- disabled by default: routes do not exist
p0, _ = start(PORT + 1, {})
try:
    check("disabled: page 404", call(PORT + 1, "GET", "/share")[0], 404)
    check("disabled: api 404", call(PORT + 1, "POST", "/api/v1/share/view/join")[0], 404)
finally:
    p0.terminate()

srv, data = start(PORT, {"RUPERT_SHARE": "1", "RUPERT_ACCESS_LOG": "1", "RUPERT_SHARE_MAX_VIEWERS": "1"}, logf)
X = {"x-rupert-share": "1"}
try:
    s, a, _ = call(PORT, "POST", "/auth/signup", {"email": "o@x.test", "password": PW, "org_name": "Shop", "subdomain": "shop"})
    check("signup", s, 201); O = {"Authorization": "Bearer " + a["session_token"]}
    s, t, _ = call(PORT, "POST", "/api/v1/tokens", {"name": "t", "scopes": ["inventory:read"]}, O); API = {"Authorization": "Bearer " + t["token"]}

    s, pg, h = call(PORT, "GET", "/share"); check("owner page", (s, b"Start sharing" in pg), (200, True))
    check("page CSP", "script-src 'self'" in h["Content-Security-Policy"] and "frame-ancestors 'none'" in h["Content-Security-Policy"], True)
    check("page no-referrer", h["Referrer-Policy"], "no-referrer")
    check("viewer page", call(PORT, "GET", "/v")[0], 200); check("js", call(PORT, "GET", "/v.js")[0], 200)

    # owner API: refused without auth / with API token / without the anti-CSRF header
    check("status unauth", call(PORT, "GET", "/api/v1/share/status")[0], 401)
    check("create unauth", call(PORT, "POST", "/api/v1/share/links", {}, X)[0], 401)
    check("API token refused", call(PORT, "GET", "/api/v1/share/status", hdrs=API)[0], 403)
    check("no csrf header", call(PORT, "POST", "/api/v1/share/links", {}, O)[0], 403)
    check("start no csrf header", call(PORT, "POST", "/api/v1/share/start", {}, O)[0], 403)

    s, l, _ = call(PORT, "POST", "/api/v1/share/links", {"ttl_secs": 600}, {**O, **X})
    check("link created", (s, l["token"].startswith("rshare_"), len(l["token"]), l["path"]), (201, True, 29, "/v#" + l["token"]))
    check("an explicit shorter lifetime is honoured", abs(l["expires_at"] - int(time.time()) - 600) < 10, True)
    TOK, LID = l["token"], l["id"]; V = {"Authorization": "Bearer " + TOK}
    row = sqlite3.connect(os.path.join(data, "central.db")).execute("select count(*) from audit where detail like ?", (f"%{TOK}%",)).fetchone()[0]
    check("secret not in audit", row, 0)

    # nothing before consent
    check("join before start", call(PORT, "POST", "/api/v1/share/view/join", hdrs=V)[0], 409)
    check("join bad token", call(PORT, "POST", "/api/v1/share/view/join", hdrs={"Authorization": "Bearer rshare_" + "A" * 22})[0], 401)
    check("join no token", call(PORT, "POST", "/api/v1/share/view/join")[0], 401)
    s, st, _ = call(PORT, "GET", "/api/v1/share/status", hdrs=O); check("status", (s, st["live"], st["viewers"], len(st["links"])), (200, False, [], 1))

    check("start", call(PORT, "POST", "/api/v1/share/start", {}, {**O, **X})[0], 200)
    s, j, _ = call(PORT, "POST", "/api/v1/share/view/join", hdrs=V); check("join", s, 200); VID = j["vid"]
    check("second viewer capped", call(PORT, "POST", "/api/v1/share/view/join", hdrs=V)[0], 409)
    check("pending viewer cannot signal", call(PORT, "POST", "/api/v1/share/view/signal", {"vid": VID, "kind": "answer", "data": {}}, V)[0], 409)
    check("owner cannot offer to pending", call(PORT, "POST", "/api/v1/share/signal", {"vid": VID, "kind": "offer", "data": {}}, {**O, **X})[0], 409)

    vc, vr = sse(PORT, f"/api/v1/share/view/events?vid={VID}", V)
    check("viewer sse", (vr.status, vr.getheader("content-type")), (200, "text/event-stream"))
    check("sse once only", call(PORT, "GET", f"/api/v1/share/view/events?vid={VID}", hdrs=V)[0], 409)
    oc, orr = sse(PORT, "/api/v1/share/events", O)
    ev = events(orr, "snapshot")
    check("owner snapshot lists the pending viewer", (ev[0][0], [(v["vid"], v["state"]) for v in ev[0][1]["viewers"]]), ("snapshot", [(VID, "pending")]))
    check("owner admit", call(PORT, "POST", f"/api/v1/share/viewers/{VID}/admit", {}, {**O, **X})[0], 200)
    check("viewer admitted", events(vr, "admitted")[-1][0], "admitted")
    check("offer", call(PORT, "POST", "/api/v1/share/signal", {"vid": VID, "kind": "offer", "data": {"sdp": "x"}}, {**O, **X})[0], 200)
    got = events(vr, "signal")[-1]; check("viewer got offer", (got[0], got[1]["kind"]), ("signal", "offer"))
    check("answer", call(PORT, "POST", "/api/v1/share/view/signal", {"vid": VID, "kind": "answer", "data": {"sdp": "y"}}, V)[0], 200)
    check("viewer cannot send offer", call(PORT, "POST", "/api/v1/share/view/signal", {"vid": VID, "kind": "offer", "data": {}}, V)[0], 409)
    big = {"sdp": "z" * 40000}
    check("oversize signal", call(PORT, "POST", "/api/v1/share/view/signal", {"vid": VID, "kind": "ice", "data": big}, V)[0], 413)

    # revoke ends the viewer immediately
    check("revoke", call(PORT, "DELETE", f"/api/v1/share/links/{LID}", None, {**O, **X})[0], 200)
    check("viewer told ended", events(vr, "ended")[-1], ("ended", {"reason": "link_revoked"}))
    check("revoked link refused", call(PORT, "POST", "/api/v1/share/view/join", hdrs=V)[0], 401)
    check("revoke unknown", call(PORT, "DELETE", "/api/v1/share/links/slnk_nope", None, {**O, **X})[0], 404)
    vc.close(); oc.close()

    # stop kills every link
    s, l2, _ = call(PORT, "POST", "/api/v1/share/links", {}, {**O, **X}); V2 = {"Authorization": "Bearer " + l2["token"]}
    check("default link lifetime is 24 hours", abs(l2["expires_at"] - int(time.time()) - 86400) < 10, True)
    s, l3, _ = call(PORT, "POST", "/api/v1/share/links", {"ttl_secs": 864000}, {**O, **X})
    check("a request for longer than the maximum is clamped to 24 hours", (s, abs(l3["expires_at"] - int(time.time()) - 86400) < 10), (201, True))
    check("join live", call(PORT, "POST", "/api/v1/share/view/join", hdrs=V2)[0], 200)
    check("stop", call(PORT, "POST", "/api/v1/share/stop", {}, {**O, **X})[0], 200)
    check("join after stop", call(PORT, "POST", "/api/v1/share/view/join", hdrs=V2)[0], 401)
    s, st, _ = call(PORT, "GET", "/api/v1/share/status", hdrs=O); check("status after stop", (st["live"], st["viewers"], st["links"]), (False, [], []))

    # another tenant cannot touch this owner's links (rooms are per signed-in owner)
    s, b, _ = call(PORT, "POST", "/auth/signup", {"email": "p@x.test", "password": PW, "org_name": "Other", "subdomain": "other"}); P = {"Authorization": "Bearer " + b["session_token"]}
    s, l3, _ = call(PORT, "POST", "/api/v1/share/links", {}, {**O, **X})
    check("other owner cannot revoke", call(PORT, "DELETE", f"/api/v1/share/links/{l3['id']}", None, {**P, **X})[0], 404)

    # rate limits: bad secrets are budgeted per IP (20/min), then 429
    codes = [call(PORT, "POST", "/api/v1/share/view/join", hdrs={"Authorization": "Bearer rshare_" + "B" * 22})[0] for _ in range(30)]
    check("bad-secret flood gets 429", 429 in codes and codes[0] == 401, True)
    s, _, _ = call(PORT, "POST", "/api/v1/share/links", {}, {**O, **X})
    for _ in range(12): s, _, _ = call(PORT, "POST", "/api/v1/share/links", {}, {**O, **X})
    check("link creation limited (cap or rate)", s in (409, 429), True)

    # audit rows exist, none contain a secret
    rows = [r[0] for r in sqlite3.connect(os.path.join(data, "central.db")).execute("select action from audit where action like 'share_%' order by id")]
    check("audit actions", {"share_link_create", "share_start", "share_viewer_join", "share_viewer_admit", "share_link_revoke", "share_stop"} <= set(rows), True)
    time.sleep(0.3)
    logf.flush(); logtxt = open(logf.name).read()
    check("logs have route template only", ("rshare_" + "A" * 22) not in logtxt and TOK not in logtxt and "/api/v1/share/view/join" in logtxt, True)
finally:
    srv.terminate()
print(f"{total - len(fails)}/{total} checks passed")
for f in fails: print("FAIL", f)
sys.exit(1 if fails else 0)
