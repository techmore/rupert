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
    pc.ontrack = (e) => { $('video').srcObject = e.streams[0]; $('stage').hidden = false; document.querySelector('main').hidden = true; startStats(); playNow();
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
  if (!ended) { status('Reconnecting…'); setTimeout(() => { if (!ended) location.reload(); }, 1000); }
}
$('leave').onclick = async () => { if (vid) await post('leave', { vid }); finish('left'); status('You left.'); };
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && !ended && (!pc || ['failed', 'disconnected', 'closed'].includes(pc.connectionState))) location.reload(); });
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
    if (frames > 0 && $('video').paused) { const p = $('video').play(); if (p && p.catch) p.catch((e) => { if (e && e.name === 'NotAllowedError') { $('tap').hidden = false; status('Picture is arriving. Tap the screen to start it.'); } }); }
    lastFrames = frames;
    let cand = '';
    (await pc.getStats()).forEach((r) => { if (r.type === 'candidate-pair' && r.nominated) cand = r.state + ' rtt=' + r.currentRoundTripTime; });
    post('diag', { text: 'viewer: pc=' + pc.connectionState + ' ice=' + pc.iceConnectionState + ' framesDecoded=' + frames + ' ' + w + 'x' + h + ' video=' + $('video').videoWidth + 'x' + $('video').videoHeight + ' paused=' + $('video').paused + ' pair=' + cand + ' ua=' + navigator.userAgent.slice(0, 90) }).catch(() => {});
  }, 2000);
}
$('fs').onclick = () => { const s = $('stage'); (s.requestFullscreen || s.webkitRequestFullscreen || (() => { $('video').webkitEnterFullscreen && $('video').webkitEnterFullscreen(); })).call(s); };
$('leave2').onclick = () => $('leave').click();
$('stage').addEventListener('click', () => { $('stage').classList.remove('idle'); clearTimeout(idleTimer); idleTimer = setTimeout(() => $('stage').classList.add('idle'), 4000); });

// iOS Safari often refuses to start a video without a tap: try, then offer a one-tap button.
function playNow() {
  const vd = $('video');
  vd.muted = true; vd.setAttribute('playsinline', ''); vd.setAttribute('webkit-playsinline', '');
  // Muted inline autoplay is allowed, so retry quietly as data arrives; the button shows only if the browser actually refuses.
  const ok = () => { $('tap').hidden = true; };
  const refused = () => { $('tap').hidden = false; };
  const attempt = () => { const p = vd.play(); if (p && p.then) p.then(ok).catch((e) => { if (e && e.name === 'NotAllowedError') refused(); }); };
  vd.onplaying = ok;
  vd.onloadedmetadata = attempt; vd.onloadeddata = attempt; vd.oncanplay = attempt;
  attempt();
  let tries = 0;
  const t = setInterval(() => { if (!vd.paused || ++tries > 20) { clearInterval(t); return; } attempt(); }, 500);
}
$('tap').onclick = (e) => { e.stopPropagation(); const vd = $('video'); vd.muted = true; vd.play().then(() => { $('tap').hidden = true; }).catch(() => status('This browser will not play the picture. Try Safari or Chrome.', 'err')); };

// Picture in picture: standard API (Chrome, Edge, desktop Safari) or Safari's presentation mode (iPhone/iPad).
// It has to start from a tap, so it is a button; Safari and Chrome also enter it on their own when you leave the page if allowed.
const vdPip = $('video');
const canPip = () => (document.pictureInPictureEnabled && !vdPip.disablePictureInPicture) || (vdPip.webkitSupportsPresentationMode && vdPip.webkitSupportsPresentationMode('picture-in-picture'));
$('pip').hidden = !canPip();
$('pip').onclick = async (e) => {
  e.stopPropagation();
  try {
    if (document.pictureInPictureElement) await document.exitPictureInPicture();
    else if (vdPip.requestPictureInPicture) await vdPip.requestPictureInPicture();
    else if (vdPip.webkitSetPresentationMode) vdPip.webkitSetPresentationMode(vdPip.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
  } catch (_) { status('Picture in picture is not available here.', 'err'); }
};
if ('mediaSession' in navigator) { try { navigator.mediaSession.setActionHandler('enterpictureinpicture', () => vdPip.requestPictureInPicture && vdPip.requestPictureInPicture().catch(() => {})); } catch (_) {} }

// Pinch to zoom, drag to pan, double-tap to toggle zoom. The picture is the full-resolution screen, so zooming shows real detail.
const zoom = { s: 1, x: 0, y: 0 };
const stageEl = $('stage'), vz = $('video');
function fitted() { // the video's on-screen box at scale 1 (object-fit: contain)
  const W = stageEl.clientWidth, H = stageEl.clientHeight, vw = vz.videoWidth || W, vh = vz.videoHeight || H;
  const r = Math.min(W / vw, H / vh); return { w: vw * r, h: vh * r, W, H };
}
function applyZoom() {
  const f = fitted();
  zoom.s = Math.min(6, Math.max(1, zoom.s));
  const mw = Math.max(0, (f.w * zoom.s - f.W) / 2), mh = Math.max(0, (f.h * zoom.s - f.H) / 2);
  const cx = (f.W - f.w) / 2, cy = (f.H - f.h) / 2;           // top-left of the fitted picture
  // keep the picture covering the screen along any axis where it is larger than the screen, centred otherwise
  const minX = f.w * zoom.s > f.W ? f.W - (cx + f.w) * zoom.s : (f.W - f.w * zoom.s) / 2 - cx * zoom.s;
  const maxX = f.w * zoom.s > f.W ? -cx * zoom.s : minX;
  const minY = f.h * zoom.s > f.H ? f.H - (cy + f.h) * zoom.s : (f.H - f.h * zoom.s) / 2 - cy * zoom.s;
  const maxY = f.h * zoom.s > f.H ? -cy * zoom.s : minY;
  zoom.x = Math.min(maxX, Math.max(minX, zoom.x)); zoom.y = Math.min(maxY, Math.max(minY, zoom.y));
  vz.style.transform = 'translate(' + zoom.x + 'px,' + zoom.y + 'px) scale(' + zoom.s + ')';
  stageEl.dataset.zoom = zoom.s.toFixed(2);
}
function zoomAt(px, py, ns) { // keep the point under the fingers fixed while changing scale
  const k = ns / zoom.s; zoom.x = px - (px - zoom.x) * k; zoom.y = py - (py - zoom.y) * k; zoom.s = ns; applyZoom();
}
const ptrs = new Map(); let pinch0 = null, lastTap = 0, moved = false;
stageEl.addEventListener('pointerdown', (e) => { if (e.target.closest('#bar,#tap')) return; stageEl.setPointerCapture(e.pointerId); ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY }); moved = false;
  if (ptrs.size === 2) { const [a, b] = [...ptrs.values()]; pinch0 = { d: Math.hypot(a.x - b.x, a.y - b.y), s: zoom.s }; } });
stageEl.addEventListener('pointermove', (e) => {
  const p = ptrs.get(e.pointerId); if (!p) return;
  const dx = e.clientX - p.x, dy = e.clientY - p.y; p.x = e.clientX; p.y = e.clientY;
  if (Math.abs(dx) + Math.abs(dy) > 1) moved = true;
  if (ptrs.size >= 2 && pinch0) { const [a, b] = [...ptrs.values()]; zoomAt((a.x + b.x) / 2, (a.y + b.y) / 2, pinch0.s * Math.hypot(a.x - b.x, a.y - b.y) / pinch0.d); }
  else if (ptrs.size === 1 && zoom.s > 1) { zoom.x += dx; zoom.y += dy; applyZoom(); }
});
const up = (e) => { if (!ptrs.has(e.pointerId)) return; ptrs.delete(e.pointerId); if (ptrs.size < 2) pinch0 = null;
  if (ptrs.size === 0 && !moved && e.type === 'pointerup') { const now = Date.now();
    if (now - lastTap < 300) { if (zoom.s > 1.05) { zoom.s = 1; zoom.x = 0; zoom.y = 0; applyZoom(); } else zoomAt(e.clientX, e.clientY, 2.5); lastTap = 0; } else lastTap = now; } };
stageEl.addEventListener('pointerup', up); stageEl.addEventListener('pointercancel', up);
stageEl.addEventListener('wheel', (e) => { e.preventDefault(); zoomAt(e.clientX, e.clientY, zoom.s * Math.exp(-Math.max(-400, Math.min(400, e.deltaY)) * 0.0025)); }, { passive: false });
addEventListener('resize', applyZoom); addEventListener('orientationchange', () => setTimeout(applyZoom, 300));
// iOS Safari's own page-zoom gesture would fight ours.
['gesturestart', 'gesturechange'].forEach((n) => stageEl.addEventListener(n, (e) => e.preventDefault()));

// iPhone/iPad niceties, each only when the browser offers it.
// 1. Keep the screen awake while watching (a locked phone would drop the stream).
let wake = null;
async function keepAwake() { try { if ('wakeLock' in navigator && !wake) { wake = await navigator.wakeLock.request('screen'); wake.addEventListener('release', () => { wake = null; }); } } catch (_) {} }
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && !$('stage').hidden) keepAwake(); });
new MutationObserver(() => { if (!$('stage').hidden) keepAwake(); }).observe($('stage'), { attributes: true, attributeFilter: ['hidden'] });
// 2. AirPlay: send the picture to an Apple TV / HomePod-with-screen from Safari's own target picker.
if (vdPip.webkitShowPlaybackTargetPicker) {
  vdPip.addEventListener('webkitplaybacktargetavailabilitychanged', (e) => { $('airplay').hidden = e.availability !== 'available'; });
  $('airplay').onclick = (e) => { e.stopPropagation(); vdPip.webkitShowPlaybackTargetPicker(); };
}
// 3. iOS's real fullscreen player (hides Safari's bars; has its own pinch zoom and PiP). Zoom in this page is for the inline view.
if (vdPip.webkitEnterFullscreen && !document.fullscreenEnabled) {
  $('native').hidden = false;
  $('native').onclick = (e) => { e.stopPropagation(); try { vdPip.webkitEnterFullscreen(); } catch (_) {} };
  $('fs').hidden = true;
}
// 4. Lock-screen / Control Center card instead of a blank player.
if ('mediaSession' in navigator && window.MediaMetadata) { try { navigator.mediaSession.metadata = new MediaMetadata({ title: 'Shared screen', artist: 'Screen Share (view only)' }); } catch (_) {} }
