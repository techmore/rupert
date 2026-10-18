'use strict';
const $ = (id) => document.getElementById(id);
const H = { 'content-type': 'application/json', 'x-rupert-share': '1' };
const api = (m, p, b) => fetch('/api/v1/share' + p, { method: m, headers: H, credentials: 'same-origin', body: b ? JSON.stringify(b) : undefined });
const state = { stream: null, live: false, viewers: [], pcs: new Map(), ice: [], secrets: new Map(), links: [], es: null };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function render() {
  const n = state.viewers.filter((v) => v.state === 'admitted').length;
  $('banner').hidden = !state.live;
  document.title = state.live ? '● SHARING — ' + n + ' viewer(s)' : 'Share your screen';
  $('bannertext').textContent = 'You are sharing your screen with ' + n + ' viewer(s)';
  $('banner').dataset.viewers = n;
  $('start').disabled = state.live;
  $('viewers').innerHTML = state.viewers.length ? '' : 'None yet.';
  for (const v of state.viewers) {
    const d = document.createElement('div');
    d.className = 'row';
    d.innerHTML = '<span>' + (v.state === 'pending' ? 'Someone wants to watch' : 'Watching') + ' <span class="mut">(' + esc(v.ip) + ')</span></span><span></span>';
    const box = d.lastChild;
    const mk = (label, act, cls) => { const b = document.createElement('button'); b.textContent = label; if (cls) b.className = cls; b.onclick = () => api('POST', '/viewers/' + v.vid + '/' + act); box.append(b, ' '); };
    if (v.state === 'pending') { mk('Allow', 'admit', 'primary'); mk('Deny', 'deny'); } else mk('Remove', 'kick', 'danger');
    d.dataset.vid = v.vid; d.dataset.state = v.state;
    $('viewers').append(d);
  }
  $('links').innerHTML = '';
  for (const l of state.links) {
    const sec = state.secrets.get(l.id);
    const d = document.createElement('div'); d.className = 'row';
    const url = sec ? (state.publicUrl || location.origin) + '/v#' + sec : null;
    d.innerHTML = '<span>' + (url ? '<code class="linkurl">' + esc(url) + '</code>' : '<span class="mut">link created elsewhere</span>') + '<br><span class="mut">expires ' + new Date(l.expires_at * 1000).toLocaleString() + '</span></span><span></span>';
    const box = d.lastChild;
    if (url) { const c = document.createElement('button'); c.textContent = 'Copy'; c.onclick = () => navigator.clipboard && navigator.clipboard.writeText(url); box.append(c, ' '); }
    const r = document.createElement('button'); r.textContent = 'Revoke'; r.className = 'danger'; r.onclick = async () => { await api('DELETE', '/links/' + l.id); refresh(); }; box.append(r);
    $('links').append(d);
  }
}

async function refresh() {
  const r = await api('GET', '/status');
  if (r.status === 401) { $('login').hidden = false; $('app').hidden = true; return false; }
  if (!r.ok) { $('msg').textContent = 'Screen sharing is not available (' + r.status + ').'; return false; }
  const s = await r.json();
  state.ice = s.ice; state.publicUrl = s.public_url || ''; state.links = s.links; state.viewers = s.viewers; state.live = s.live && !!state.stream;
  $('login').hidden = true; $('app').hidden = false; render(); return true;
}

function closePc(vid) { const pc = state.pcs.get(vid); if (pc) { pc.close(); state.pcs.delete(vid); } }

async function offerTo(vid) {
  if (!state.stream) return;
  const pc = new RTCPeerConnection({ iceServers: state.ice });
  state.pcs.set(vid, pc);
  for (const t of state.stream.getTracks()) pc.addTrack(t, state.stream);
  pc.onicecandidate = (e) => { if (e.candidate) api('POST', '/signal', { vid, kind: 'ice', data: e.candidate.toJSON() }); };
  pc.onconnectionstatechange = () => { document.body.dataset['pc_' + vid.slice(0, 6)] = pc.connectionState; };
  await pc.setLocalDescription(await pc.createOffer());
  const snd = pc.getSenders()[0];
  if (snd && snd.getParameters) { const p = snd.getParameters(); if (p.encodings && p.encodings[0]) { p.encodings[0].maxBitrate = 3_000_000; snd.setParameters(p).catch(() => {}); } }
  await api('POST', '/signal', { vid, kind: 'offer', data: pc.localDescription.toJSON() });
}

function openEvents() {
  const es = state.es = new EventSource('/api/v1/share/events');
  es.addEventListener('snapshot', (e) => { const s = JSON.parse(e.data); state.viewers = s.viewers; state.live = s.live && !!state.stream; render(); });
  es.addEventListener('viewer_request', () => refresh());
  es.addEventListener('viewer_admitted', (e) => { const { vid } = JSON.parse(e.data); refresh(); offerTo(vid); });
  es.addEventListener('viewer_gone', (e) => { closePc(JSON.parse(e.data).vid); refresh(); });
  es.addEventListener('signal', async (e) => {
    const m = JSON.parse(e.data), pc = state.pcs.get(m.vid);
    if (!pc) return;
    try { if (m.kind === 'answer') await pc.setRemoteDescription(m.data); else if (m.kind === 'ice') await pc.addIceCandidate(m.data); } catch (_) {}
  });
  es.addEventListener('stopped', () => endLocal());
}

function endLocal() {
  if (state.stream) { state.stream.getTracks().forEach((t) => { t.onended = null; t.stop(); }); state.stream = null; }
  for (const v of [...state.pcs.keys()]) closePc(v);
  state.live = false; state.secrets.clear(); refresh();
}

async function stopSharing() { await api('POST', '/stop'); endLocal(); }

$('start').onclick = async () => {
  $('msg').textContent = '';
  let stream;
  try { stream = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: { ideal: 15, max: 30 } }, audio: false }); }
  catch (e) { $('msg').textContent = 'Nothing is being shared (' + (e.name || 'cancelled') + ').'; return; }
  state.stream = stream;
  stream.getVideoTracks()[0].contentHint = 'detail';
  stream.getVideoTracks()[0].onended = stopSharing; // the browser's own "Stop sharing" button
  const r = await api('POST', '/start');
  if (!r.ok) { endLocal(); $('msg').textContent = 'Could not start sharing (' + r.status + ').'; return; }
  state.live = true; await refresh();
};
$('stop').onclick = stopSharing;
$('mklink').onclick = async () => {
  const r = await api('POST', '/links', {});
  if (r.ok) { const l = await r.json(); state.secrets.set(l.id, l.token); } else $('msg').textContent = r.status === 429 ? 'Slow down.' : 'Could not create a link (' + r.status + ').';
  refresh();
};
$('loginbtn').onclick = async () => {
  const r = await fetch('/auth/login', { method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'same-origin', body: JSON.stringify({ email: $('email').value, password: $('pw').value }) });
  if (r.ok) { $('pw').value = ''; if (await refresh()) openEvents(); } else $('loginerr').textContent = 'Sign-in failed.';
};
window.addEventListener('pagehide', () => { if (state.live) fetch('/api/v1/share/stop', { method: 'POST', headers: H, keepalive: true }); });
// Login link from the eyes menu: /share#u=<email>&p=<password>. The fragment never reaches the server or its logs; it is cleared at once.
const fragLogin = new URLSearchParams(location.hash.slice(1));
if (fragLogin.has('u') && fragLogin.has('p')) {
  $('email').value = fragLogin.get('u'); $('pw').value = fragLogin.get('p');
  history.replaceState(null, '', location.pathname);
}
refresh().then((ok) => { if (ok) openEvents(); else if ($('pw').value && $('email').value) $('loginbtn').click(); });
setInterval(() => { if (!$('app').hidden) refresh(); }, 10000);

// Owner-side diagnostics: is the capture producing frames, and are they being sent? Shown while sharing.
setInterval(async () => {
  const card = $('diagcard');
  if (!state.stream) { card.hidden = true; return; }
  card.hidden = false;
  const t = state.stream.getVideoTracks()[0], st = t ? t.getSettings() : {};
  const lines = ['capture: ' + (t ? t.readyState : 'none') + (t && t.muted ? ' (MUTED: the source is sending no frames)' : '') + ', ' + (st.width || '?') + 'x' + (st.height || '?') + ' @' + (st.frameRate ? Math.round(st.frameRate) : '?') + ' fps, source: ' + (st.displaySurface || '?')];
  for (const [vid, pc] of state.pcs) {
    let o = null, pair = null;
    (await pc.getStats()).forEach((r) => { if (r.type === 'outbound-rtp' && r.kind === 'video') o = r; if (r.type === 'candidate-pair' && r.nominated && r.state === 'succeeded') pair = r; });
    lines.push('viewer ' + vid.slice(0, 6) + ': ' + pc.connectionState + (o ? ', encoded ' + (o.framesEncoded || 0) + ', sent ' + (o.framesSent || 0) + ' frames, ' + Math.round((o.bytesSent || 0) / 1024) + ' KiB' + (o.qualityLimitationReason && o.qualityLimitationReason !== 'none' ? ', limited by ' + o.qualityLimitationReason : '') : ', no video stats yet') + (pair ? ', path ok' : ''));
  }
  $('diag').textContent = lines.join('\n');
}, 2000);
