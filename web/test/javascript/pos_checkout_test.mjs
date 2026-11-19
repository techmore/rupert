import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/javascript/controllers/pos_checkout_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*$/gm, (line) => (line.includes('@hotwired/stimulus') ? 'class Controller {}' : ''))
  .replace('export default class', 'globalThis.PosCheckout = class');
const context = {};
vm.createContext(context);
vm.runInContext(source, context);
const PosCheckout = context.PosCheckout;

// The register posts a checkout and reads JSON back. When the answer is a page instead (the
// session ran out, the server is restarting), the cashier must get words they can act on, not
// the browser's "The string did not match the expected pattern."
test('a sign-in page in place of the answer says the cashier was signed out', () => {
  const message = PosCheckout.unreadableAnswer({ status: 200, redirected: true, url: 'https://shop.example/login' });
  assert.match(message, /signed out/);
  assert.match(message, /Unfinished/);
  assert.match(PosCheckout.unreadableAnswer({ status: 401, redirected: false, url: '' }), /signed out/);
});

test('an error page says what to do and never claims the payment outcome', () => {
  for (const status of [404, 500, 502, 503]) {
    const message = PosCheckout.unreadableAnswer({ status, redirected: false, url: 'https://shop.example/pos_checkouts' });
    assert.match(message, new RegExp(String(status)));
    assert.match(message, /Do not take payment again yet/);
    assert.match(message, /ask a manager/);
    assert.doesNotMatch(message, /not charged|nothing was charged|was paid/i);
  }
});

test('a redirect somewhere other than sign-in is not called a sign-out', () => {
  const message = PosCheckout.unreadableAnswer({ status: 200, redirected: true, url: 'https://shop.example/employee' });
  assert.doesNotMatch(message, /signed out/);
});
