// Screenshots of the owner and viewer pages for design review (bun tests/share_shots.mjs OUT_DIR [server-binary]).
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const OUT = process.argv[2] || '/tmp/share-shots';
const BIN = process.argv[3] || new URL('../target/debug/rupert-core', import.meta.url).pathname;
const BROWSER = process.env.BROWSER_BIN || '/opt/brave.com/brave/brave';
const PORT = 8795, BASE = `http://127.0.0.1:${PORT}`;
const MDNS_MASK = false;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
mkdirSync(OUT, { recursive: true });
const tmp = mkdtempSync(join(tmpdir(), 'share-shots-'));
const procs = [];
const server = spawn(BIN, [], { env: { ...process.env, RUPERT_DATA: join(tmp, 'data'), RUPERT_LISTEN: `127.0.0.1:${PORT}`, RUPERT_COOKIE_SECURE: '0', RUPERT_SIGNUP: 'open', RUPERT_SCHEDULER: '0', RUPERT_SHARE: '1', RUPERT_SHARE_STUN: '' }, stdio: 'ignore' });
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
const shot = async (pg, name) => { await pg.send('Page.bringToFront'); await sleep(250); const r = await pg.send('Page.captureScreenshot', { format: 'png' }); writeFileSync(join(OUT, name + '.png'), Buffer.from(r.result.data, 'base64')); console.log('shot', name); };
try {
  for (let i = 0; i < 50; i++) { try { if ((await fetch(BASE + '/healthz')).ok) break; } catch {} await sleep(100); }
  const su = await (await fetch(BASE + '/auth/signup', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: 'o@x.test', password: 'correct-horse-battery', org_name: 'Shop', subdomain: 'shop' }) })).json();
  const COOKIE = 'rupert_session=' + su.session_token;
  const owner = await launch(9341, 'o'), viewer = await launch(9342, 'v'), phone = await launch(9343, 'p');
  await owner.send('Emulation.setDeviceMetricsOverride', { width: 520, height: 760, deviceScaleFactor: 1, mobile: false });
  await owner.send('Page.addScriptToEvaluateOnNewDocument', { source: STUB });
  await owner.goto(BASE + '/share'); await owner.until(`!document.getElementById('login').hidden`); await shot(owner, '1-signin');
  await owner.goto(BASE + '/share#u=o%40x.test&p=correct-horse-battery');  await owner.until(`!document.getElementById('app').hidden`); await sleep(300); await shot(owner, '2-ready');
  await owner.eval(`document.getElementById('start').click()`); await owner.until('window.__gdmPending'); await owner.eval('window.__grant()');
  await owner.until(`!document.getElementById('banner').hidden`); await sleep(900); await shot(owner, '3-live-no-viewers');
  const tok = (await owner.eval(`document.querySelector('.linkurl') ? document.querySelector('.linkurl').textContent : ''`)).split('/v/')[1];
  await phone.send('Emulation.setDeviceMetricsOverride', { width: 390, height: 780, deviceScaleFactor: 2, mobile: true });
  await phone.goto(BASE + '/v/' + tok); await sleep(1500); await shot(phone, '4-viewer-waiting-for-allow');
  await owner.until(`document.querySelector('[data-state=pending]')`); await sleep(300); await shot(owner, '5-owner-someone-wants-to-watch');
  await owner.eval(`document.querySelector('[data-state=pending] button.primary').click()`);
  await owner.until(`document.body.dataset.viewers !== undefined || document.querySelector('[data-state=admitted]')`); await sleep(2500);
  await shot(owner, '6-owner-watching'); await shot(phone, '7-viewer-live');
  console.log(await phone.eval(`JSON.stringify({main:document.querySelector('main').hidden,stage:document.getElementById('stage').hidden,st:document.getElementById('vstat').textContent,pc:document.body.dataset.pc,v:document.getElementById('video').videoWidth,disp:getComputedStyle(document.getElementById('stage')).display,vis:getComputedStyle(document.getElementById('video')).visibility})`));
} finally { for (const p of procs) try { p.kill(); } catch {} setTimeout(() => process.exit(0), 300); }
