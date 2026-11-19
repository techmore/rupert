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

// The outcome line under the pay button: its look follows what happened, and anything the
// cashier must act on is brought into view (on a phone it sits below the fold).
test('the outcome tone follows the checkout status', () => {
  assert.equal(PosCheckout.tone('paid'), 'ok');
  assert.equal(PosCheckout.tone('declined'), 'error');
  assert.equal(PosCheckout.tone('processing'), 'warn');
  assert.equal(PosCheckout.tone('unknown'), 'warn');
  assert.equal(PosCheckout.tone('ready'), '');
});

test('say sets the words and the tone, scrolls a toned message into view and clears the tone after', () => {
  let scrolled = 0;
  const controller = new PosCheckout();
  controller.statusTarget = { textContent: '', dataset: {}, scrollIntoView: () => { scrolled += 1; } };
  controller.say('Cash received is less than the total.', 'error');
  assert.equal(controller.statusTarget.textContent, 'Cash received is less than the total.');
  assert.equal(controller.statusTarget.dataset.tone, 'error');
  assert.equal(scrolled, 1);
  controller.say('Checking source totals and payment…');
  assert.equal(controller.statusTarget.dataset.tone, undefined);
  assert.equal(scrolled, 1);
});
