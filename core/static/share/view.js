'use strict';
const $ = (id) => document.getElementById(id);
// The key comes from /v/<key> (or the older /v#<key>), is remembered for this tab so a reload still works, and is then
// removed from the address bar so it is not left in screenshots.
const fromUrl = location.pathname.startsWith('/v/') ? decodeURIComponent(location.pathname.slice(3)) : location.hash.slice(1);
let token = fromUrl;
try { if (token) sessionStorage.setItem('rshare_key', token); else token = sessionStorage.getItem('rshare_key') || ''; } catch (_) {}
history.replaceState(null, '', '/v');
const status = (t, cls) => { $('vstat').textContent = t; $('vstat').className = cls || ''; $('vstat2').textContent = t; };
let statsTimer = null, lastFrames = -1, idleTimer = null;
const auth = { authorization: 'Bearer ' + token, 'content-type': 'application/json' };
const post = (p, b) => fetch('/api/v1/share/view/' + p, { method: 'POST', headers: auth, body: JSON.stringify(b), keepalive: true });
let vid = null, pc = null, ended = false;

async function join() {
  for (;;) {
    const r = await fetch('/api/v1/share/view/join', { method: 'POST', headers: auth });
    if (r.ok) return r.json();
    if (r.status === 409) { const m = (await r.json()).error; status(m === 'viewer limit reached' ? 'Someone is already watching this link.' : 'Waiting for the host to start sharing…'); await new Promise((s) => setTimeout(s, 5000)); continue; }
    status(r.status === 429 ? 'Too many attempts. Wait a minute.' : 'This link is invalid, expired or was revoked.', 'err'); return null;
  }
}

async function onSignal(m, ice) {
  if (m.kind === 'offer') {
    pc = new RTCPeerConnection({ iceServers: ice });
    pc.onicecandidate = (e) => { if (e.candidate) post('signal', { vid, kind: 'ice', data: e.candidate.toJSON() }); };
    pc.ontrack = (e) => { $('video').srcObject = e.streams[0]; $('stage').hidden = false; document.querySelector('main').hidden = true; startStats(); $('video').play().catch(() => {});
       $('video').onclick = () => $('video').play().catch(() => {}); };
    pc.onconnectionstatechange = () => {
      document.body.dataset.pc = pc.connectionState;
      if (pc.connectionState === 'failed') status('Could not connect to the host (the network blocked the direct path). Try the host\'s tailnet link.', 'err');
      else if (pc.connectionState === 'connected') status('Connected. Waiting for the first picture… (a window that is not changing sends nothing)');
    };
    await pc.setRemoteDescription(m.data);
    await pc.setLocalDescription(await pc.createAnswer());
    await post('signal', { vid, kind: 'answer', data: pc.localDescription.toJSON() });
  } else if (m.kind === 'ice' && pc) await pc.addIceCandidate(m.data).catch(() => {});
}

function finish(why) {
  ended = true; if (pc) pc.close(); $('video').srcObject = null; $('stage').hidden = true; document.querySelector('main').hidden = false; $('leave').hidden = true; clearInterval(statsTimer);
  status({ stopped: 'The host stopped sharing.', denied: 'The host declined.', removed: 'The host removed you.', link_revoked: 'The link was revoked.', timeout: 'The host did not respond in time.', owner_disconnected: 'The host went away.', time_limit: 'The share reached its time limit.' }[why] || 'The share ended.');
}

async function run() {
  if (!token) return status('This link is missing its key. Ask the host to copy the link again from the eyes menu, and open the whole link.', 'err');
  const j = await join(); if (!j) return;
  vid = j.vid; status('Waiting for the host to allow you…'); $('leave').hidden = false;
  const r = await fetch('/api/v1/share/view/events?vid=' + vid, { headers: auth });
  if (!r.ok) return status('Could not connect.', 'err');
  const rd = r.body.getReader(), dec = new TextDecoder(); let buf = '', chain = Promise.resolve();
  for (;;) {
    const { done, value } = await rd.read(); if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const blk = buf.slice(0, i); buf = buf.slice(i + 2);
      let ev = 'message', data = '';
      for (const ln of blk.split('\n')) { if (ln.startsWith('event:')) ev = ln.slice(6).trim(); else if (ln.startsWith('data:')) data += ln.slice(5).trim(); }
      if (!data) continue;
      const d = JSON.parse(data);
      if (ev === 'admitted') status('Allowed. Connecting…');
      else if (ev === 'signal') chain = chain.then(() => onSignal(d, j.ice)).catch(() => {});
      else if (ev === 'ended') { finish(d.reason); return; }
    }
  }
  if (!ended) finish('');
}
$('leave').onclick = async () => { if (vid) await post('leave', { vid }); finish('left'); status('You left.'); };
addEventListener('pagehide', () => { if (vid && !ended) post('leave', { vid }); });
run();

// Say what the connection is actually doing: a black picture with 'Live' hides whether frames arrive at all.
function startStats() {
  clearInterval(statsTimer);
  statsTimer = setInterval(async () => {
    if (!pc) return;
    let frames = 0, w = 0, h = 0;
    (await pc.getStats()).forEach((r) => { if (r.type === 'inbound-rtp' && r.kind === 'video') { frames = r.framesDecoded || 0; w = r.frameWidth || 0; h = r.frameHeight || 0; } });
    if (frames === 0) status('Connected, but no picture has arrived yet. On the host, share the whole screen or move the shared window.');
    else if (frames === lastFrames) status('Live (' + w + '×' + h + '), the shared window is not changing');
    else status('Live (view only) ' + w + '×' + h);
    lastFrames = frames;
  }, 2000);
}
$('fs').onclick = () => { const s = $('stage'); (s.requestFullscreen || s.webkitRequestFullscreen || (() => { $('video').webkitEnterFullscreen && $('video').webkitEnterFullscreen(); })).call(s); };
$('leave2').onclick = () => $('leave').click();
$('stage').addEventListener('click', () => { $('stage').classList.remove('idle'); clearTimeout(idleTimer); idleTimer = setTimeout(() => $('stage').classList.add('idle'), 4000); });
