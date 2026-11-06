import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

// The offline queue of the PIN clock (pin_clock_controller.js): punches kept with their
// request_token until the server has them, dropped once accepted or refused.
const source = readFileSync(new URL('../../app/javascript/controllers/pin_clock_controller.js', import.meta.url), 'utf8')
  .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
  .replace(/export function /g, 'function ')
  .replace('export default class', 'globalThis.PinClock = class');
const context = { globalThis: {} };
vm.createContext(context);
vm.runInContext(source, context);
const { queuedPunches, enqueuePunch, dequeuePunch, queueable, requestToken } =
  vm.runInContext('({ queuedPunches, enqueuePunch, dequeuePunch, queueable, requestToken })', context);

class Storage {
  constructor() { this.map = new Map(); }
  getItem(key) { return this.map.has(key) ? this.map.get(key) : null; }
  setItem(key, value) { this.map.set(key, String(value)); }
  removeItem(key) { this.map.delete(key); }
}

const storage = new Storage();
assert.equal(queuedPunches(storage).length, 0);
assert.equal(enqueuePunch({ request_token: 'a', clock_action: 'punch', pin: '2580' }, storage), 1);
assert.equal(enqueuePunch({ request_token: 'b', clock_action: 'clock_out', pin: '2580' }, storage), 2);
assert.equal(enqueuePunch({ request_token: 'a', clock_action: 'punch', pin: '2580', punched_at: 'later' }, storage), 2, 'same token replaces, never duplicates');
assert.equal(queuedPunches(storage).find(p => p.request_token === 'a').punched_at, 'later');
assert.equal(dequeuePunch('a', storage), 1);
assert.equal(dequeuePunch('b', storage), 0);
assert.equal(storage.getItem('rupert.pinClock.queue'), null, 'an empty queue leaves nothing behind');

storage.setItem('rupert.pinClock.queue', '{not json');
assert.equal(queuedPunches(storage).length, 0, 'a corrupt queue is ignored');

assert.ok(queueable('punch'));
assert.ok(queueable('clock_out'));
assert.ok(!queueable('fix_and_clock_in'), 'a fix needs the server’s options; never replayed blind');

const token = requestToken();
assert.match(token, /^[0-9a-f]{32}$/);
assert.notEqual(token, requestToken());
console.log('pin_clock offline queue ok');
