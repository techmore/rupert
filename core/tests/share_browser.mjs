// Headless two-browser end-to-end test of the screen-share demo (run with: bun tests/share_browser.mjs [server-binary]).
// Two separate Chromium-family browsers (own profiles, headless, no window on any screen) talk to a throwaway server.
// The browser's native screen picker cannot be driven headlessly, so navigator.mediaDevices.getDisplayMedia is replaced
// in the OWNER page only by a stub that returns an animated canvas stream, and only after this test "grants" it.
// Everything else (signaling, consent gates, WebRTC peer connection, media decode) is real.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const BIN = process.argv[2] || new URL('../target/debug/rupert-core', import.meta.url).pathname;
const BROWSER = process.env.BROWSER_BIN || '/opt/brave.com/brave/brave';
const PORT = 8794, BASE = `http://127.0.0.1:${PORT}`;
// Network modes (all optional; the default is everything on loopback with mDNS masking off, as before):
//   LISTEN_HOST=0.0.0.0        make the server reachable on the machine's real addresses
//   VIEWER_HOST=192.168.x.y    the viewer opens the link through that address instead of 127.0.0.1 (how a second device connects;
//                              the OWNER page stays on 127.0.0.1, which browsers treat as a secure context for screen capture)
//   MDNS_MASK=1                keep Chromium's default WebRTC privacy (local addresses hidden behind mDNS names)
const LISTEN = process.env.LISTEN_HOST || '127.0.0.1', VHOST = process.env.VIEWER_HOST || '127.0.0.1', MDNS_MASK = process.env.MDNS_MASK === '1';
// When the viewer is not on loopback the server is told its public origin, and the link is used EXACTLY as the owner page shows it.
const PUBLIC = VHOST !== '127.0.0.1' ? `http://${VHOST}:${PORT}` : '';
const forViewer = (l) => l;
console.log(`# mode: server on ${LISTEN}, viewer via ${VHOST}, mDNS masking ${MDNS_MASK ? 'ON (browser default)' : 'off'}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const fails = []; let total = 0;
const check = (name, ok, extra = '') => { total++; if (!ok) fails.push(name + (extra ? ' :: ' + extra : '')); console.log((ok ? 'ok   ' : 'FAIL ') + name + (extra ? '  ' + extra : '')); };
const median = (a) => { const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };

const tmp = mkdtempSync(join(tmpdir(), 'share-e2e-'));
const procs = [];
const server = spawn(BIN, [], { env: { ...process.env, RUPERT_DATA: join(tmp, 'data'), RUPERT_LISTEN: `${LISTEN}:${PORT}`, RUPERT_COOKIE_SECURE: '0', RUPERT_SIGNUP: 'open', RUPERT_SCHEDULER: '0', RUPERT_SHARE: '1', RUPERT_SHARE_STUN: '', ...(PUBLIC ? { RUPERT_SHARE_PUBLIC_URL: PUBLIC } : {}) }, stdio: 'ignore' });
procs.push(server);

class Page {
  constructor(ws) { this.ws = ws; this.id = 0; this.cb = new Map(); ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && this.cb.has(d.id)) { this.cb.get(d.id)(d); this.cb.delete(d.id); } }; }
  send(method, params = {}) { const id = ++this.id; this.ws.send(JSON.stringify({ id, method, params })); return new Promise((r) => this.cb.set(id, r)); }
  async eval(expr) { const r = await this.send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails)); return r.result?.result?.value; }
  async goto(url) { await this.send('Page.navigate', { url: 'about:blank' }); await sleep(100); await this.send('Page.navigate', { url }); await sleep(400); }
  async until(expr, ms = 8000) { const t = Date.now(); for (;;) { try { if (await this.eval(expr)) return Date.now() - t; } catch {} if (Date.now() - t > ms) throw new Error('timeout waiting for: ' + expr); await sleep(50); } }
}

async function launch(port, name) {
  const dir = join(tmp, name);
  const p = spawn(BROWSER, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${dir}`, '--no-first-run', '--no-default-browser-check', '--disable-gpu', '--autoplay-policy=no-user-gesture-required', ...(MDNS_MASK ? [] : ['--disable-features=WebRtcHideLocalIpsWithMdns']), 'about:blank'], { stdio: 'ignore' });
  procs.push(p);
  for (let i = 0; i < 100; i++) { try { const l = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); const t = l.find((x) => x.type === 'page'); if (t) { const ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise((r) => (ws.onopen = r)); const pg = new Page(ws); await pg.send('Page.enable'); await pg.send('Runtime.enable'); return pg; } } catch {} await sleep(100); }
  throw new Error('browser did not start: ' + name);
}

const STUB = `(() => {
  let res, rej;
  navigator.mediaDevices.getDisplayMedia = () => new Promise((a, b) => { res = a; rej = b; window.__gdmPending = true; });
  window.__grant = () => { const c = document.createElement('canvas'); c.width = 640; c.height = 360; const x = c.getContext('2d'); let n = 0;
    setInterval(() => { x.fillStyle = 'hsl(' + (n * 7 % 360) + ',70%,50%)'; x.fillRect(0, 0, 640, 360); x.fillStyle = '#fff'; x.font = '40px sans-serif'; x.fillText('frame ' + n++, 40, 180); }, 33);
    window.__stream = c.captureStream(15); window.__gdmPending = false; res(window.__stream); };
  window.__deny = () => { window.__gdmPending = false; rej(new DOMException('denied', 'NotAllowedError')); };
  window.__browserStop = () => { const t = window.__stream.getVideoTracks()[0]; t.stop(); t.dispatchEvent(new Event('ended')); };
})();`;

const frames = (v) => v.eval(`document.getElementById('video').getVideoPlaybackQuality().totalVideoFrames`);
const status = (v) => v.eval(`document.getElementById('vstat').textContent`);
const srv = async (path, cookie) => (await fetch(BASE + '/api/v1/share' + path, { headers: { cookie } })).json();

try {
  for (let i = 0; i < 50; i++) { try { if ((await fetch(BASE + '/healthz')).ok) break; } catch {} await sleep(100); }
  const su = await (await fetch(BASE + '/auth/signup', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: 'o@x.test', password: 'correct-horse-battery', org_name: 'Shop', subdomain: 'shop' }) })).json();
  const COOKIE = 'rupert_session=' + su.session_token;
  const owner = await launch(9331, 'owner'), viewer = await launch(9332, 'viewer');
  await owner.send('Page.addScriptToEvaluateOnNewDocument', { source: STUB });

  // --- owner signs in through the page, makes a link
  await owner.goto(BASE + '/share');
  await owner.until(`!document.getElementById('login').hidden`);
  await owner.eval(`document.getElementById('email').value='o@x.test';document.getElementById('pw').value='correct-horse-battery';document.getElementById('loginbtn').click()`);
  await owner.until(`!document.getElementById('app').hidden`);
  await owner.eval(`document.getElementById('mklink').click()`);
  await owner.until(`document.querySelector('.linkurl')`);
  const link = await owner.eval(`document.querySelector('.linkurl').textContent`);
  check('the link on the owner page uses the address buddies can reach', link.startsWith((PUBLIC || BASE) + '/v#'), link.replace(/rshare_.+/, 'rshare_…'));
  { // login link from the eyes menu: prefilled through the URL fragment, signs in, fragment cleared
    const lg = await launch(9333, 'login');
    await lg.goto(BASE + '/share#u=o%40x.test&p=correct-horse-battery');
    const ok = await lg.until(`!document.getElementById('app').hidden`).then(() => true, () => false);
    check('login link: page signs in from the URL fragment', ok, ok ? '' : await lg.eval(`JSON.stringify({href:location.href,em:document.getElementById('email').value,err:document.getElementById('loginerr').textContent,login:document.getElementById('login').hidden})`));
    check('login link: fragment (with the password) is cleared from the address bar', !(await lg.eval('location.href')).includes('correct-horse'));
    await lg.close?.();
  }
  check('owner page shows a /v#rshare_ link', /\/v#rshare_[A-Za-z0-9_-]{22}$/.test(link), link.replace(/rshare_.+/, 'rshare_…'));

  // --- before consent: viewer opens link, gets nothing
  await viewer.goto(forViewer(link));
  await viewer.until(`/Waiting for the host to start/.test(document.getElementById('vstat').textContent)`);
  check('viewer waits while owner has not started', true);
  check(`viewer page was served from ${VHOST}, not just loopback`, (await viewer.eval('location.hostname')) === VHOST);
  check('viewer URL bar no longer carries the secret', !(await viewer.eval('location.href')).includes('rshare_'));
  { const s0 = await srv('/status', COOKIE); check('server: not live, no viewers before consent', !s0.live && s0.viewers.length === 0); }

  // --- owner clicks Start but the (stubbed) picker is still open: still nothing shared
  await owner.eval(`document.getElementById('start').click()`);
  await owner.until(`window.__gdmPending === true`);
  await sleep(1500);
  check('picker open, no consent yet: banner hidden', await owner.eval(`document.getElementById('banner').hidden`));
  check('picker open, no consent yet: server not live', !(await srv('/status', COOKIE)).live);
  check('picker open, no consent yet: viewer has no video', (await viewer.eval(`document.getElementById('video').hidden`)) && !(await viewer.eval(`!!document.getElementById('video').srcObject`)));

  // --- owner denies once: still nothing
  await owner.eval(`window.__deny()`);
  await owner.until(`/Nothing is being shared/.test(document.getElementById('msg').textContent)`);
  check('denied capture: nothing shared, server not live', !(await srv('/status', COOKIE)).live);

  // --- grant
  await owner.eval(`document.getElementById('start').click()`);
  await owner.until(`window.__gdmPending === true`);
  await owner.eval(`window.__grant()`);
  await owner.until(`!document.getElementById('banner').hidden`);
  check('banner visible after grant', /You are sharing your screen with 0 viewer/.test(await owner.eval(`document.getElementById('bannertext').textContent`)));
  check('tab title marks sharing', /SHARING/.test(await owner.eval('document.title')));

  // viewer (still polling) joins, but is only pending until the owner allows
  await owner.until(`document.querySelector('#viewers [data-state=pending]')`, 12000);
  await sleep(1500);
  check('pending viewer receives no frames before Allow', (await viewer.eval(`!document.getElementById('video').srcObject`)));

  // --- allow, then measure time to first decoded frame; repeat for a small median
  const times = [];
  for (let round = 0; round < 5; round++) {
    if (round > 0) { // fresh viewer page on the same link
      await owner.until(`document.querySelectorAll('#viewers .row').length===0`, 15000);
      await viewer.goto(forViewer(link));
      await owner.until(`document.querySelector('#viewers [data-state=pending]')`, 12000);
    }
    const t0 = Date.now();
    await owner.eval(`document.querySelector('#viewers [data-state=pending] button.primary').click()`);
    await viewer.until(`document.getElementById('video').getVideoPlaybackQuality().totalVideoFrames >= 1`, 15000);
    times.push(Date.now() - t0);
    if (round === 0) {
      const a = await frames(viewer); await sleep(1200); const b = await frames(viewer);
      check('viewer receives live frames (counter advances)', b > a + 5, `frames ${a} -> ${b}`);
      check('video has real dimensions', (await viewer.eval(`document.getElementById('video').videoWidth`)) === 640);
      check('owner banner counts 1 viewer', await owner.until(`document.getElementById('banner').dataset.viewers==='1'`).then(() => true, () => false));
    }
    if (round < 4) await owner.eval(`document.querySelector('#viewers [data-state=admitted] button').click()`); // Remove
  }
  console.log(`# allow -> first decoded frame, ms, 5 rounds: ${times.join(', ')}  median ${median(times)}`);

  // --- owner clicks Stop: viewer is cut off, frames stop, link is dead
  await sleep(1500); const pre = await frames(viewer);
  await owner.eval(`document.getElementById('stop').click()`);
  await viewer.until(`/host stopped sharing/.test(document.getElementById('vstat').textContent)`, 8000);
  const f1 = await frames(viewer); await sleep(1200); const f2 = await frames(viewer);
  check('after Stop: viewer frames stop and video is released', pre > 5 && f2 === f1 && !(await viewer.eval(`!!document.getElementById('video').srcObject`)), `frames before Stop ${pre}, after ${f1} -> ${f2}`);
  check('after Stop: owner banner hidden, server not live', (await owner.eval(`document.getElementById('banner').hidden`)) && !(await srv('/status', COOKIE)).live);
  await viewer.goto(forViewer(link));
  await viewer.until(`/invalid, expired/.test(document.getElementById('vstat').textContent)`);
  check('after Stop: the old link is refused', true);

  // --- browser-native "Stop sharing" (track ended) ends the share too
  await owner.eval(`document.getElementById('mklink').click()`);
  await owner.until(`document.querySelector('.linkurl')`);
  const link2 = await owner.eval(`document.querySelector('.linkurl').textContent`);
  await owner.eval(`document.getElementById('start').click()`); await owner.until(`window.__gdmPending === true`); await owner.eval(`window.__grant()`);
  await owner.until(`!document.getElementById('banner').hidden`);
  await viewer.goto(forViewer(link2));
  await owner.until(`document.querySelector('#viewers [data-state=pending]')`, 12000);
  await owner.eval(`document.querySelector('#viewers [data-state=pending] button.primary').click()`);
  await viewer.until(`document.getElementById('video').getVideoPlaybackQuality().totalVideoFrames >= 1`, 15000);
  await owner.eval(`window.__browserStop()`);
  await viewer.until(`/host stopped sharing/.test(document.getElementById('vstat').textContent)`, 8000);
  check('browser-native stop ends the share for the viewer', !(await srv('/status', COOKIE)).live);
} catch (e) {
  fails.push('exception: ' + e.message); console.log('EXCEPTION', e);
} finally {
  for (const p of procs) p.kill('SIGTERM');
  await sleep(300);
  rmSync(tmp, { recursive: true, force: true });
}
console.log(`${total - fails.filter((f) => !f.startsWith('exception')).length}/${total} checks passed`);
for (const f of fails) console.log('FAIL', f);
process.exit(fails.length ? 1 : 0);
