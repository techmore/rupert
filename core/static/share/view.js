'use strict';
const $ = (id) => document.getElementById(id);
const token = location.hash.slice(1);
history.replaceState(null, '', location.pathname); // keep the secret out of the address bar, history and screenshots
const status = (t, cls) => { $('vstat').textContent = t; $('vstat').className = cls || ''; };
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
    pc.ontrack = (e) => { $('video').srcObject = e.streams[0]; $('video').hidden = false; status('Live (view only)'); };
    pc.onconnectionstatechange = () => { document.body.dataset.pc = pc.connectionState; };
    await pc.setRemoteDescription(m.data);
    await pc.setLocalDescription(await pc.createAnswer());
    await post('signal', { vid, kind: 'answer', data: pc.localDescription.toJSON() });
  } else if (m.kind === 'ice' && pc) await pc.addIceCandidate(m.data).catch(() => {});
}

function finish(why) {
  ended = true; if (pc) pc.close(); $('video').srcObject = null; $('video').hidden = true; $('leave').hidden = true;
  status({ stopped: 'The host stopped sharing.', denied: 'The host declined.', removed: 'The host removed you.', link_revoked: 'The link was revoked.', timeout: 'The host did not respond in time.', owner_disconnected: 'The host went away.', time_limit: 'The share reached its time limit.' }[why] || 'The share ended.');
}

async function run() {
  if (!token) return status('This link is incomplete.', 'err');
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
