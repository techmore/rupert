//! Consent-gated screen-share demo: a signed-in owner shares their screen to a buddy over WebRTC.
//! This module is only the signaling plane (SSE + POST) and the link/viewer bookkeeping; media flows
//! peer to peer and never touches the server. Everything is in memory on purpose: a restart ends every
//! share, and there is no recording or stored link. Disabled (routes absent, so 404) unless `RUPERT_SHARE=1`.
//! Design and threat model: docs/SCREEN-SHARE.md.
use crate::{
    auth::{self, Principal, client_key, err, limit, sha_hex},
    tenants::Registry,
};
use axum::{
    Json, Router,
    extract::{ConnectInfo, DefaultBodyLimit, Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{
        IntoResponse, Response, Sse,
        sse::{Event, KeepAlive},
    },
    routing::{delete, get, post},
};
use parking_lot::Mutex;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::HashMap, convert::Infallible, net::SocketAddr, sync::Arc, time::Duration};
use tokio::sync::{broadcast, mpsc};
use tokio_stream::{StreamExt, wrappers::ReceiverStream};

type RoomKey = (String, i64); // (tenant, owner user): one room per signed-in owner
type Msg = (String, String); // (SSE event name, JSON data)

const PENDING_SECS: i64 = 60;
const OWNER_GRACE_SECS: i64 = 15;
const MAX_LINKS: usize = 5;
const MAX_OWNER_STREAMS: usize = 3;
const MAX_SIGNAL_BYTES: usize = 32 * 1024;

#[derive(Clone, Copy, PartialEq, Debug)]
enum VState {
    Pending,
    Admitted,
}

struct Viewer {
    link: String,
    state: VState,
    since: i64,
    ip: String,
    tx: mpsc::Sender<Msg>,
    rx: Option<mpsc::Receiver<Msg>>,
}

struct Room {
    live: bool,
    live_since: i64,
    owner_conns: usize,
    gone_at: i64,
    tx: broadcast::Sender<Msg>,
    viewers: HashMap<String, Viewer>,
}

struct Link {
    id: String,
    room: RoomKey,
    expires: i64,
}

#[derive(Default)]
struct Inner {
    rooms: HashMap<RoomKey, Room>,
    links: HashMap<String, Link>, // SHA-256 digest of the secret -> link; the secret itself is never stored
}

pub struct ShareState {
    inner: Mutex<Inner>,
    max_viewers: usize,
    ttl_max: i64,
    ttl_default: i64,
    live_max: i64,
    stun: Vec<String>,
    turn: Option<(String, String, String)>,
    /// Origin buddies should use in links (`RUPERT_SHARE_PUBLIC_URL`). The owner page itself must be opened on a secure
    /// origin (127.0.0.1 or https), which is usually not an address anyone else can reach.
    public_url: Option<String>,
}

/// Accepts only a bare http(s) origin: no path, query, fragment, userinfo or whitespace.
pub fn parse_public_url(raw: &str) -> Option<String> {
    let v = raw.trim().trim_end_matches('/');
    let rest = v
        .strip_prefix("https://")
        .or_else(|| v.strip_prefix("http://"))?;
    let ok_chars = rest
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b':' | b'[' | b']'));
    (v.len() <= 200
        && !rest.is_empty()
        && ok_chars
        && !rest.starts_with(':')
        && !rest.contains("::-"))
    .then(|| v.to_string())
}

/// What the state machine asks the caller to record in the central audit table.
pub type AuditNote = (RoomKey, &'static str, String);

fn rand_hex(n: usize) -> String {
    let mut b = vec![0u8; n];
    getrandom::fill(&mut b).expect("os randomness");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// 128-bit random link secret, URL-safe (22 chars).
fn link_secret() -> String {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).expect("os randomness");
    format!("rshare_{}", URL_SAFE_NO_PAD.encode(b))
}

fn env_num<T: std::str::FromStr>(k: &str, d: T) -> T {
    std::env::var(k)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(d)
}

pub fn enabled() -> bool {
    std::env::var("RUPERT_SHARE").as_deref() == Ok("1")
}

impl ShareState {
    pub fn new() -> Self {
        let stun = std::env::var("RUPERT_SHARE_STUN")
            .unwrap_or_else(|_| "stun:stun.l.google.com:19302".into())
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect();
        let turn = match (
            std::env::var("RUPERT_SHARE_TURN").ok(),
            std::env::var("RUPERT_SHARE_TURN_USER").ok(),
            std::env::var("RUPERT_SHARE_TURN_CRED").ok(),
        ) {
            (Some(u), Some(n), Some(c)) if !u.is_empty() => Some((u, n, c)),
            _ => None,
        };
        let ttl_max = env_num("RUPERT_SHARE_LINK_TTL_MAX", 86_400i64).max(60);
        Self {
            inner: Mutex::new(Inner::default()),
            max_viewers: env_num("RUPERT_SHARE_MAX_VIEWERS", 1usize).clamp(1, 8),
            ttl_max,
            // Defaults are 24 hours for both a link's lifetime and a share's maximum running time (the owner's decision);
            // both stay configurable, and a link can still ask for something shorter.
            ttl_default: env_num("RUPERT_SHARE_LINK_TTL", 86_400i64).clamp(60, ttl_max),
            live_max: env_num("RUPERT_SHARE_MAX_SECS", 86_400i64).max(60),
            stun,
            turn,
            public_url: std::env::var("RUPERT_SHARE_PUBLIC_URL").ok().and_then(|v| {
                let parsed = parse_public_url(&v);
                if parsed.is_none() && !v.trim().is_empty() {
                    eprintln!("{{\"level\":\"warn\",\"msg\":\"RUPERT_SHARE_PUBLIC_URL ignored: it must be a bare http(s) origin such as https://host or http://192.168.1.5:8799\"}}");
                }
                parsed
            }),
        }
    }

    pub fn ttl_default(&self) -> i64 {
        self.ttl_default
    }

    pub fn public_url(&self) -> Option<&str> {
        self.public_url.as_deref()
    }

    pub fn ice(&self) -> Value {
        let mut v: Vec<Value> = Vec::new();
        if !self.stun.is_empty() {
            v.push(json!({ "urls": self.stun }));
        }
        if let Some((u, n, c)) = &self.turn {
            v.push(json!({ "urls": [u], "username": n, "credential": c }));
        }
        Value::Array(v)
    }

    fn room<'a>(i: &'a mut Inner, k: &RoomKey) -> &'a mut Room {
        i.rooms.entry(k.clone()).or_insert_with(|| Room {
            live: false,
            live_since: 0,
            owner_conns: 0,
            gone_at: 0,
            tx: broadcast::channel(256).0,
            viewers: HashMap::new(),
        })
    }

    fn end_viewer(room: &mut Room, vid: &str, reason: &str) -> bool {
        let Some(v) = room.viewers.remove(vid) else {
            return false;
        };
        let _ =
            v.tx.try_send(("ended".into(), json!({ "reason": reason }).to_string()));
        let _ = room.tx.send((
            "viewer_gone".into(),
            json!({ "vid": vid, "reason": reason }).to_string(),
        ));
        true
    }

    fn snapshot(room: &Room) -> Value {
        let mut vs: Vec<Value> = room
            .viewers
            .iter()
            .map(|(id, v)| {
                json!({ "vid": id, "state": if v.state == VState::Admitted { "admitted" } else { "pending" }, "since": v.since, "ip": v.ip })
            })
            .collect();
        vs.sort_by_key(|v| v["since"].as_i64());
        json!({ "live": room.live, "viewers": vs })
    }

    pub fn status(&self, k: &RoomKey) -> Value {
        let i = self.inner.lock();
        let mut links: Vec<Value> = i
            .links
            .values()
            .filter(|l| &l.room == k)
            .map(|l| json!({ "id": l.id, "expires_at": l.expires }))
            .collect();
        links.sort_by_key(|l| l["expires_at"].as_i64());
        let mut s = i
            .rooms
            .get(k)
            .map_or(json!({ "live": false, "viewers": [] }), Self::snapshot);
        s["links"] = Value::Array(links);
        s["max_viewers"] = json!(self.max_viewers);
        s
    }

    pub fn create_link(
        &self,
        k: &RoomKey,
        ttl: i64,
        now: i64,
    ) -> Result<(String, String, i64), (u16, &'static str)> {
        let ttl = ttl.clamp(60, self.ttl_max);
        let mut i = self.inner.lock();
        i.links.retain(|_, l| l.expires > now);
        if i.links.values().filter(|l| &l.room == k).count() >= MAX_LINKS {
            return Err((409, "too many active links; revoke one"));
        }
        let (secret, id) = (link_secret(), format!("slnk_{}", rand_hex(6)));
        let exp = now + ttl;
        i.links.insert(
            sha_hex(&secret),
            Link {
                id: id.clone(),
                room: k.clone(),
                expires: exp,
            },
        );
        Ok((secret, id, exp))
    }

    pub fn revoke_link(&self, k: &RoomKey, id: &str) -> bool {
        let mut i = self.inner.lock();
        let Some(dig) = i
            .links
            .iter()
            .find(|(_, l)| l.id == id && &l.room == k)
            .map(|(d, _)| d.clone())
        else {
            return false;
        };
        i.links.remove(&dig);
        if let Some(r) = i.rooms.get_mut(k) {
            let vids: Vec<String> = r
                .viewers
                .iter()
                .filter(|(_, v)| v.link == id)
                .map(|(x, _)| x.clone())
                .collect();
            for v in vids {
                Self::end_viewer(r, &v, "link_revoked");
            }
        }
        true
    }

    pub fn start(&self, k: &RoomKey, now: i64) {
        let mut i = self.inner.lock();
        let r = Self::room(&mut i, k);
        if !r.live {
            r.live = true;
            r.live_since = now;
        }
    }

    /// Ends the share: every viewer is cut off and every link for this room dies with it.
    pub fn stop(&self, k: &RoomKey, reason: &str) -> bool {
        let mut i = self.inner.lock();
        i.links.retain(|_, l| &l.room != k);
        let Some(r) = i.rooms.get_mut(k) else {
            return false;
        };
        let was = r.live;
        r.live = false;
        let vids: Vec<String> = r.viewers.keys().cloned().collect();
        for v in vids {
            Self::end_viewer(r, &v, reason);
        }
        let _ =
            r.tx.send(("stopped".into(), json!({ "reason": reason }).to_string()));
        was
    }

    /// Viewer joins with a link secret's digest. Returns (vid, room, link id).
    pub fn join(
        &self,
        digest: &str,
        ip: &str,
        now: i64,
    ) -> Result<(String, RoomKey, String), (u16, &'static str)> {
        let mut i = self.inner.lock();
        let Some(l) = i.links.get(digest) else {
            return Err((401, "invalid or expired link"));
        };
        if l.expires <= now {
            return Err((401, "invalid or expired link"));
        }
        let (rk, lid) = (l.room.clone(), l.id.clone());
        let Some(r) = i.rooms.get_mut(&rk).filter(|r| r.live) else {
            return Err((409, "the host is not sharing right now"));
        };
        if r.viewers.len() >= self.max_viewers {
            return Err((409, "viewer limit reached"));
        }
        let vid = rand_hex(16);
        let (tx, rx) = mpsc::channel(64);
        r.viewers.insert(
            vid.clone(),
            Viewer {
                link: lid.clone(),
                state: VState::Pending,
                since: now,
                ip: ip.to_string(),
                tx,
                rx: Some(rx),
            },
        );
        let _ = r.tx.send((
            "viewer_request".into(),
            json!({ "vid": vid, "ip": ip, "since": now }).to_string(),
        ));
        Ok((vid, rk, lid))
    }

    /// Looks up a joined viewer by link digest + vid; the link must still exist (not revoked).
    fn with_viewer<T>(
        &self,
        digest: &str,
        vid: &str,
        f: impl FnOnce(&mut Room, &RoomKey) -> Option<T>,
    ) -> Result<T, (u16, &'static str)> {
        let mut i = self.inner.lock();
        let Some(l) = i.links.get(digest) else {
            return Err((401, "invalid or expired link"));
        };
        let (rk, lid) = (l.room.clone(), l.id.clone());
        let r = i.rooms.get_mut(&rk).ok_or((404, "no such viewer"))?;
        if r.viewers.get(vid).is_none_or(|v| v.link != lid) {
            return Err((404, "no such viewer"));
        }
        f(r, &rk).ok_or((409, "not allowed in this state"))
    }

    pub fn viewer_rx(
        &self,
        digest: &str,
        vid: &str,
    ) -> Result<mpsc::Receiver<Msg>, (u16, &'static str)> {
        self.with_viewer(digest, vid, |r, _| r.viewers.get_mut(vid)?.rx.take())
    }

    pub fn viewer_signal(
        &self,
        digest: &str,
        vid: &str,
        kind: &str,
        data: Value,
    ) -> Result<(), (u16, &'static str)> {
        self.with_viewer(digest, vid, |r, _| {
            if r.viewers.get(vid)?.state != VState::Admitted || !matches!(kind, "answer" | "ice") {
                return None;
            }
            let _ = r.tx.send((
                "signal".into(),
                json!({ "vid": vid, "kind": kind, "data": data }).to_string(),
            ));
            Some(())
        })
    }

    pub fn viewer_leave(
        &self,
        digest: &str,
        vid: &str,
        reason: &str,
    ) -> Result<(), (u16, &'static str)> {
        self.with_viewer(digest, vid, |r, _| {
            Self::end_viewer(r, vid, reason).then_some(())
        })
    }

    /// Called when a viewer's event stream is dropped (tab closed, network gone).
    pub fn viewer_dropped(&self, vid: &str) {
        let mut i = self.inner.lock();
        for r in i.rooms.values_mut() {
            if Self::end_viewer(r, vid, "disconnected") {
                return;
            }
        }
    }

    pub fn owner_viewer_action(
        &self,
        k: &RoomKey,
        vid: &str,
        action: &str,
    ) -> Result<(), (u16, &'static str)> {
        let mut i = self.inner.lock();
        let r = i.rooms.get_mut(k).ok_or((404, "no such viewer"))?;
        let st = r
            .viewers
            .get(vid)
            .map(|v| v.state)
            .ok_or((404, "no such viewer"))?;
        match action {
            "admit" => {
                if !r.live {
                    return Err((409, "start sharing first"));
                }
                if st != VState::Pending {
                    return Err((409, "already admitted"));
                }
                let v = r.viewers.get_mut(vid).unwrap();
                v.state = VState::Admitted;
                let _ = v.tx.try_send(("admitted".into(), "{}".into()));
                let _ =
                    r.tx.send(("viewer_admitted".into(), json!({ "vid": vid }).to_string()));
            }
            "deny" if st == VState::Pending => {
                Self::end_viewer(r, vid, "denied");
            }
            "kick" => {
                Self::end_viewer(r, vid, "removed");
            }
            _ => return Err((400, "unknown action")),
        }
        Ok(())
    }

    pub fn owner_signal(
        &self,
        k: &RoomKey,
        vid: &str,
        kind: &str,
        data: Value,
    ) -> Result<(), (u16, &'static str)> {
        let mut i = self.inner.lock();
        let r = i.rooms.get_mut(k).ok_or((404, "no such viewer"))?;
        let v = r.viewers.get(vid).ok_or((404, "no such viewer"))?;
        if v.state != VState::Admitted || !r.live || !matches!(kind, "offer" | "ice") {
            return Err((409, "not allowed in this state"));
        }
        let full =
            v.tx.try_send((
                "signal".into(),
                json!({ "kind": kind, "data": data }).to_string(),
            ))
            .is_err();
        if full {
            Self::end_viewer(r, vid, "overflow");
        }
        Ok(())
    }

    fn owner_attach(&self, k: &RoomKey) -> Option<(broadcast::Receiver<Msg>, Value)> {
        let mut i = self.inner.lock();
        let r = Self::room(&mut i, k);
        if r.owner_conns >= MAX_OWNER_STREAMS {
            return None;
        }
        r.owner_conns += 1;
        r.gone_at = 0;
        Some((r.tx.subscribe(), Self::snapshot(r)))
    }

    fn owner_detach(&self, k: &RoomKey) {
        if let Some(r) = self.inner.lock().rooms.get_mut(k) {
            r.owner_conns = r.owner_conns.saturating_sub(1);
            if r.owner_conns == 0 {
                r.gone_at = crate::now();
            }
        }
    }

    /// Periodic housekeeping. Returns audit notes for anything it ended on its own.
    pub fn sweep(&self, now: i64) -> Vec<AuditNote> {
        let mut notes = Vec::new();
        let mut stop: Vec<(RoomKey, &'static str)> = Vec::new();
        {
            let mut i = self.inner.lock();
            i.links.retain(|_, l| l.expires > now);
            for (k, r) in i.rooms.iter_mut() {
                let stale: Vec<String> = r
                    .viewers
                    .iter()
                    .filter(|(_, v)| v.state == VState::Pending && now - v.since >= PENDING_SECS)
                    .map(|(x, _)| x.clone())
                    .collect();
                for v in stale {
                    Self::end_viewer(r, &v, "timeout");
                }
                if r.live
                    && r.owner_conns == 0
                    && r.gone_at > 0
                    && now - r.gone_at >= OWNER_GRACE_SECS
                {
                    stop.push((k.clone(), "owner_disconnected"));
                } else if r.live && now - r.live_since >= self.live_max {
                    stop.push((k.clone(), "time_limit"));
                }
            }
            i.rooms
                .retain(|_, r| r.live || r.owner_conns > 0 || !r.viewers.is_empty());
        }
        for (k, why) in stop {
            if self.stop(&k, why) {
                notes.push((k, "share_stop", why.to_string()));
            }
        }
        notes
    }
}

pub async fn janitor(reg: Arc<Registry>) {
    let mut down = reg.shutdown.subscribe();
    loop {
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(5)) => {}
            _ = down.changed() => return,
        }
        for (k, a, d) in reg.share.sweep(crate::now()) {
            audit(&reg, &k, a, d);
        }
    }
}

// ---------- http ----------

fn audit(reg: &Arc<Registry>, k: &RoomKey, action: &'static str, detail: String) {
    let (r, k) = (reg.clone(), k.clone());
    tokio::task::spawn_blocking(move || {
        auth::audit(&r.central.lock(), Some(&k.0), Some(k.1), action, &detail)
    });
}

fn fail(e: (u16, &'static str)) -> Response {
    err(e.0, e.1)
}

fn owner(p: &Principal, h: &HeaderMap, mutating: bool) -> Result<RoomKey, Response> {
    if p.token_id.is_some() {
        return Err(err(
            403,
            "screen sharing needs a signed-in session, not an API token",
        ));
    }
    p.require("share:manage", "manager")?;
    // A custom header forces a CORS preflight, so another site cannot drive these with the owner's cookie.
    if mutating && h.get("x-rupert-share").is_none() {
        return Err(err(403, "missing X-Rupert-Share header"));
    }
    Ok((p.tenant_id.clone(), p.user_id))
}

fn bearer(h: &HeaderMap) -> Option<String> {
    let v = h
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")?;
    (v.starts_with("rshare_") && v.len() == 29).then(|| sha_hex(v))
}

/// A viewer call with a missing/unknown secret: counts against a per-IP failure budget.
fn denied(reg: &Registry, ip: &str, e: (u16, &'static str)) -> Response {
    if e.0 == 401
        && let Err(r) = limit(reg, format!("share-bad|{ip}"), 20)
    {
        return r;
    }
    fail(e)
}

fn viewer_ctx(reg: &Registry, ci: SocketAddr, h: &HeaderMap) -> Result<(String, String), Response> {
    let ip = client_key(reg, ci, h);
    limit(reg, format!("share-view|{ip}"), 240)?;
    match bearer(h) {
        Some(d) => Ok((ip, d)),
        None => Err(denied(reg, &ip, (401, "invalid or expired link"))),
    }
}

async fn create_link(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    h: HeaderMap,
    body: Option<Json<Value>>,
) -> Result<Response, Response> {
    let k = owner(&p, &h, true)?;
    limit(&reg, format!("share-link|{}|{}", k.0, k.1), 10)?;
    let ttl = body
        .and_then(|b| b.0["ttl_secs"].as_i64())
        .unwrap_or_else(|| reg.share.ttl_default());
    let (secret, id, exp) = reg.share.create_link(&k, ttl, crate::now()).map_err(fail)?;
    audit(&reg, &k, "share_link_create", id.clone());
    Ok((
        StatusCode::CREATED,
        Json(
            json!({ "id": id, "token": secret, "expires_at": exp, "path": format!("/v/{secret}") }),
        ),
    )
        .into_response())
}

async fn status(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    h: HeaderMap,
) -> Result<Response, Response> {
    let k = owner(&p, &h, false)?;
    let mut s = reg.share.status(&k);
    s["ice"] = reg.share.ice();
    s["public_url"] = reg
        .share
        .public_url()
        .map(Value::from)
        .unwrap_or(Value::Null);
    Ok(Json(s).into_response())
}

async fn revoke_link(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    h: HeaderMap,
    Path(id): Path<String>,
) -> Result<Response, Response> {
    let k = owner(&p, &h, true)?;
    if !reg.share.revoke_link(&k, &id) {
        return Err(err(404, "not found"));
    }
    audit(&reg, &k, "share_link_revoke", id);
    Ok(Json(json!({ "ok": true })).into_response())
}

async fn start(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    h: HeaderMap,
) -> Result<Response, Response> {
    let k = owner(&p, &h, true)?;
    limit(&reg, format!("share-start|{}|{}", k.0, k.1), 20)?;
    reg.share.start(&k, crate::now());
    audit(&reg, &k, "share_start", String::new());
    Ok(Json(json!({ "live": true })).into_response())
}

async fn stop(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    h: HeaderMap,
) -> Result<Response, Response> {
    let k = owner(&p, &h, true)?;
    reg.share.stop(&k, "stopped");
    audit(&reg, &k, "share_stop", "owner".into());
    Ok(Json(json!({ "live": false })).into_response())
}

async fn viewer_action(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    h: HeaderMap,
    Path((vid, action)): Path<(String, String)>,
) -> Result<Response, Response> {
    let k = owner(&p, &h, true)?;
    reg.share
        .owner_viewer_action(&k, &vid, &action)
        .map_err(fail)?;
    audit(
        &reg,
        &k,
        match action.as_str() {
            "admit" => "share_viewer_admit",
            "deny" => "share_viewer_deny",
            _ => "share_viewer_kick",
        },
        vid,
    );
    Ok(Json(json!({ "ok": true })).into_response())
}

#[derive(Deserialize)]
struct OwnerSignal {
    vid: String,
    kind: String,
    data: Value,
}

async fn owner_signal(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    h: HeaderMap,
    Json(b): Json<OwnerSignal>,
) -> Result<Response, Response> {
    let k = owner(&p, &h, true)?;
    limit(&reg, format!("share-osig|{}|{}", k.0, k.1), 600)?;
    if b.data.to_string().len() > MAX_SIGNAL_BYTES {
        return Err(err(413, "signal too large"));
    }
    reg.share
        .owner_signal(&k, &b.vid, &b.kind, b.data)
        .map_err(fail)?;
    Ok(Json(json!({ "ok": true })).into_response())
}

fn sse_event((name, data): Msg) -> Result<Event, Infallible> {
    Ok(Event::default().event(name).data(data))
}

struct OwnerGuard(Arc<Registry>, RoomKey);
impl Drop for OwnerGuard {
    fn drop(&mut self) {
        self.0.share.owner_detach(&self.1);
    }
}

async fn owner_events(
    State(reg): State<Arc<Registry>>,
    p: Principal,
    h: HeaderMap,
) -> Result<Response, Response> {
    let k = owner(&p, &h, false)?;
    let (mut rx, snap) = reg
        .share
        .owner_attach(&k)
        .ok_or_else(|| err(429, "too many open streams"))?;
    let guard = OwnerGuard(reg.clone(), k.clone());
    let mut down = reg.shutdown.subscribe();
    let (tx, out) = mpsc::channel::<Result<Event, Infallible>>(64);
    let _ = tx.try_send(sse_event(("snapshot".into(), snap.to_string())));
    tokio::spawn(async move {
        let _g = guard;
        loop {
            tokio::select! {
                m = rx.recv() => match m {
                    Ok(m) => if tx.send(sse_event(m)).await.is_err() { return },
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        let s = _g.0.share.inner.lock().rooms.get(&_g.1).map(ShareState::snapshot).unwrap_or(json!({"live":false,"viewers":[]}));
                        if tx.send(sse_event(("snapshot".into(), s.to_string()))).await.is_err() { return }
                    }
                    Err(_) => return,
                },
                _ = down.changed() => return,
                _ = tx.closed() => return,
            }
        }
    });
    Ok(Sse::new(ReceiverStream::new(out))
        .keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
        .into_response())
}

async fn view_join(
    State(reg): State<Arc<Registry>>,
    ConnectInfo(ci): ConnectInfo<SocketAddr>,
    h: HeaderMap,
) -> Result<Response, Response> {
    let (ip, dig) = viewer_ctx(&reg, ci, &h)?;
    limit(&reg, format!("share-join|{ip}"), 30)?;
    let (vid, rk, lid) = reg
        .share
        .join(&dig, &ip, crate::now())
        .map_err(|e| denied(&reg, &ip, e))?;
    audit(&reg, &rk, "share_viewer_join", format!("{lid} {vid}"));
    Ok(Json(json!({ "vid": vid, "ice": reg.share.ice() })).into_response())
}

#[derive(Deserialize)]
struct VidQ {
    vid: String,
}

struct ViewerGuard(Arc<Registry>, String);
impl Drop for ViewerGuard {
    fn drop(&mut self) {
        self.0.share.viewer_dropped(&self.1);
    }
}

async fn view_events(
    State(reg): State<Arc<Registry>>,
    ConnectInfo(ci): ConnectInfo<SocketAddr>,
    h: HeaderMap,
    Query(q): Query<VidQ>,
) -> Result<Response, Response> {
    let (ip, dig) = viewer_ctx(&reg, ci, &h)?;
    let rx = reg
        .share
        .viewer_rx(&dig, &q.vid)
        .map_err(|e| denied(&reg, &ip, e))?;
    let guard = ViewerGuard(reg.clone(), q.vid);
    let s = ReceiverStream::new(rx).map(move |m| {
        let _ = &guard;
        sse_event(m)
    });
    Ok(Sse::new(s)
        .keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
        .into_response())
}

#[derive(Deserialize)]
struct ViewerSignal {
    vid: String,
    kind: String,
    data: Value,
}

async fn view_signal(
    State(reg): State<Arc<Registry>>,
    ConnectInfo(ci): ConnectInfo<SocketAddr>,
    h: HeaderMap,
    Json(b): Json<ViewerSignal>,
) -> Result<Response, Response> {
    let (ip, dig) = viewer_ctx(&reg, ci, &h)?;
    limit(&reg, format!("share-vsig|{}", b.vid), 600)?;
    if b.data.to_string().len() > MAX_SIGNAL_BYTES {
        return Err(err(413, "signal too large"));
    }
    reg.share
        .viewer_signal(&dig, &b.vid, &b.kind, b.data)
        .map_err(|e| denied(&reg, &ip, e))?;
    Ok(Json(json!({ "ok": true })).into_response())
}

async fn view_leave(
    State(reg): State<Arc<Registry>>,
    ConnectInfo(ci): ConnectInfo<SocketAddr>,
    h: HeaderMap,
    Json(b): Json<VidQ>,
) -> Result<Response, Response> {
    let (ip, dig) = viewer_ctx(&reg, ci, &h)?;
    reg.share
        .viewer_leave(&dig, &b.vid, "left")
        .map_err(|e| denied(&reg, &ip, e))?;
    Ok(Json(json!({ "ok": true })).into_response())
}

fn asset(ctype: &'static str, body: &'static str) -> Response {
    let mut r = body.into_response();
    let hd = r.headers_mut();
    hd.insert(header::CONTENT_TYPE, HeaderValue::from_static(ctype));
    hd.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    hd.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    hd.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    hd.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static("default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; media-src 'self' blob:; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
    );
    r
}

pub fn routes() -> Router<Arc<Registry>> {
    if !enabled() {
        return Router::new();
    }
    const HTML: &str = "text/html; charset=utf-8";
    const JS: &str = "text/javascript; charset=utf-8";
    Router::new()
        .route(
            "/share",
            get(|| async { asset(HTML, include_str!("../static/share/share.html")) }),
        )
        .route(
            "/share.js",
            get(|| async { asset(JS, include_str!("../static/share/share.js")) }),
        )
        .route(
            "/share.css",
            get(|| async {
                asset(
                    "text/css; charset=utf-8",
                    include_str!("../static/share/share.css"),
                )
            }),
        )
        .route(
            "/v",
            get(|| async { asset(HTML, include_str!("../static/share/view.html")) }),
        )
        .route(
            "/v/{tok}",
            get(|| async { asset(HTML, include_str!("../static/share/view.html")) }),
        )
        .route(
            "/v.js",
            get(|| async { asset(JS, include_str!("../static/share/view.js")) }),
        )
        .route("/api/v1/share/status", get(status))
        .route("/api/v1/share/links", post(create_link))
        .route("/api/v1/share/links/{id}", delete(revoke_link))
        .route("/api/v1/share/start", post(start))
        .route("/api/v1/share/stop", post(stop))
        .route("/api/v1/share/events", get(owner_events))
        .route("/api/v1/share/viewers/{vid}/{action}", post(viewer_action))
        .route("/api/v1/share/signal", post(owner_signal))
        .route("/api/v1/share/view/join", post(view_join))
        .route("/api/v1/share/view/events", get(view_events))
        .route("/api/v1/share/view/signal", post(view_signal))
        .route("/api/v1/share/view/leave", post(view_leave))
        .layer(DefaultBodyLimit::max(64 * 1024))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn st(max: usize) -> ShareState {
        let mut s = ShareState::new();
        s.max_viewers = max;
        s
    }
    fn key() -> RoomKey {
        ("t1".into(), 1)
    }

    #[test]
    fn defaults_are_24_hours() {
        // Assumes the test environment does not set the RUPERT_SHARE_* overrides (CI does not).
        let s = ShareState::new();
        assert_eq!(
            (s.ttl_default(), s.ttl_max, s.live_max),
            (86_400, 86_400, 86_400)
        );
    }

    #[test]
    fn public_url_accepts_only_bare_origins() {
        for ok in [
            "https://rrupert.stoverparc.org",
            "http://192.168.222.104:8799",
            "http://100.115.140.33:8799/",
            "https://[fd00::1]:8443",
        ] {
            assert!(parse_public_url(ok).is_some(), "{ok}");
        }
        assert_eq!(
            parse_public_url(" https://a.example/ ").as_deref(),
            Some("https://a.example")
        );
        for bad in [
            "",
            "a.example",
            "ftp://a.example",
            "https://",
            "https://a.example/path",
            "https://a.example?x=1",
            "https://u:p@a.example",
            "https://a b.example",
            "javascript:alert(1)",
            "https://a.example#frag",
            "http://:80",
        ] {
            assert!(parse_public_url(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn link_expiry_and_digest_only() {
        let s = st(1);
        let (secret, _, exp) = s.create_link(&key(), 100, 1000).unwrap();
        assert_eq!(exp, 1100);
        assert!(secret.starts_with("rshare_") && secret.len() == 29);
        s.start(&key(), 1000);
        assert!(
            s.inner.lock().links.keys().all(|d| d != &secret),
            "secret must not be stored"
        );
        let d = sha_hex(&secret);
        assert!(s.join(&d, "1.2.3.4", 1099).is_ok());
        assert_eq!(s.join(&d, "1.2.3.4", 1100).unwrap_err().0, 401);
    }

    #[test]
    fn ttl_is_clamped() {
        let s = st(1);
        assert_eq!(s.create_link(&key(), 1, 0).unwrap().2, 60);
        assert_eq!(s.create_link(&key(), 10_000_000, 0).unwrap().2, 86_400);
    }

    #[test]
    fn nothing_before_consent_and_viewer_cap() {
        let s = st(1);
        let (secret, _, _) = s.create_link(&key(), 600, 0).unwrap();
        let d = sha_hex(&secret);
        assert_eq!(s.join(&d, "ip", 1).unwrap_err().0, 409, "not live yet");
        s.start(&key(), 1);
        let (v1, _, _) = s.join(&d, "ip", 2).unwrap();
        assert_eq!(s.join(&d, "ip", 2).unwrap_err().1, "viewer limit reached");
        // pending viewers get nothing signaled until the owner admits them
        assert!(s.viewer_signal(&d, &v1, "answer", json!({})).is_err());
        assert!(s.owner_signal(&key(), &v1, "offer", json!({})).is_err());
        s.owner_viewer_action(&key(), &v1, "admit").unwrap();
        assert!(s.owner_signal(&key(), &v1, "offer", json!({})).is_ok());
        assert!(s.viewer_signal(&d, &v1, "answer", json!({})).is_ok());
        assert!(
            s.viewer_signal(&d, &v1, "offer", json!({})).is_err(),
            "viewer cannot send offers"
        );
    }

    #[test]
    fn cap_is_configurable() {
        let s = st(2);
        let (secret, _, _) = s.create_link(&key(), 600, 0).unwrap();
        let d = sha_hex(&secret);
        s.start(&key(), 0);
        assert!(s.join(&d, "a", 1).is_ok() && s.join(&d, "b", 1).is_ok());
        assert!(s.join(&d, "c", 1).is_err());
    }

    #[test]
    fn revoke_ends_viewers_and_kills_link() {
        let s = st(1);
        let (secret, id, _) = s.create_link(&key(), 600, 0).unwrap();
        let d = sha_hex(&secret);
        s.start(&key(), 0);
        let (v, _, _) = s.join(&d, "ip", 1).unwrap();
        assert!(s.revoke_link(&key(), &id));
        assert_eq!(s.join(&d, "ip", 2).unwrap_err().0, 401);
        assert!(s.viewer_rx(&d, &v).is_err());
        assert!(!s.revoke_link(&key(), &id));
        assert!(!s.revoke_link(&("other".into(), 1), &id));
    }

    #[test]
    fn stop_kills_links_and_viewers() {
        let s = st(1);
        let (secret, _, _) = s.create_link(&key(), 600, 0).unwrap();
        let d = sha_hex(&secret);
        s.start(&key(), 0);
        let (v, _, _) = s.join(&d, "ip", 1).unwrap();
        s.owner_viewer_action(&key(), &v, "admit").unwrap();
        assert!(s.stop(&key(), "stopped"));
        assert_eq!(s.join(&d, "ip", 2).unwrap_err().0, 401);
        assert!(s.owner_signal(&key(), &v, "offer", json!({})).is_err());
    }

    #[test]
    fn sweep_times_out_pending_and_vanished_owner() {
        let s = st(1);
        let (secret, _, _) = s.create_link(&key(), 6000, 0).unwrap();
        let d = sha_hex(&secret);
        s.start(&key(), 0);
        let (_v, _, _) = s.join(&d, "ip", 1).unwrap();
        s.sweep(1 + PENDING_SECS);
        assert!(
            s.join(&d, "ip", 70).is_ok(),
            "pending viewer timed out, slot freed"
        );
        // owner connects then disappears
        let _ = s.owner_attach(&key()).unwrap();
        s.owner_detach(&key());
        let gone = s.inner.lock().rooms[&key()].gone_at;
        let notes = s.sweep(gone + OWNER_GRACE_SECS);
        assert_eq!(notes.len(), 1);
        assert!(!s.inner.lock().rooms.get(&key()).is_some_and(|r| r.live));
    }

    #[test]
    fn live_time_limit() {
        let s = st(1);
        s.start(&key(), 0);
        let _ = s.owner_attach(&key()).unwrap();
        assert!(s.sweep(100).is_empty());
        assert_eq!(s.sweep(s.live_max).len(), 1);
    }

    #[test]
    fn link_count_capped() {
        let s = st(1);
        for _ in 0..MAX_LINKS {
            s.create_link(&key(), 600, 0).unwrap();
        }
        assert!(s.create_link(&key(), 600, 0).is_err());
        assert!(s.create_link(&("t2".into(), 1), 600, 0).is_ok());
    }
}
