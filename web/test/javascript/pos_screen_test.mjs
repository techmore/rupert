import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/javascript/controllers/pos_screen_controller.js', import.meta.url), 'utf8')
  .replace(/^import .*$/gm, (line) => (line.includes('@hotwired/stimulus') ? 'class Controller {}' : ''))
  .replace('export default class', 'globalThis.PosScreen = class');

function load(coarse) {
  const context = { window: { matchMedia: (query) => ({ matches: coarse && query === '(pointer: coarse)' }) } };
  vm.createContext(context);
  vm.runInContext(source, context);
  const controller = new context.PosScreen();
  const calls = { focus: 0, select: 0, scroll: 0 };
  controller.hasSearchTarget = true;
  controller.searchTarget = { focus: () => { calls.focus += 1; }, select: () => { calls.select += 1; } };
  controller.element = { querySelector: () => null };
  return { controller, calls };
}

// On a phone, the cursor in Search raises the keyboard over the products.
test('a touch screen does not focus search on its own, only for a key press', () => {
  const { controller, calls } = load(true);
  controller.focusSearch(false);
  controller.itemClosed();
  controller.newSale();
  assert.equal(calls.focus, 0);
  controller.focusSearch(true, true);
  assert.equal(calls.focus, 1);
  assert.equal(calls.select, 1);
});

test('a mouse-and-keyboard register still focuses search after each step', () => {
  const { controller, calls } = load(false);
  controller.focusSearch(false);
  controller.itemClosed();
  assert.equal(calls.focus, 2);
});

test('a reload onto a waiting or declined payment opens the payment step once; a paid cart does not', () => {
  const { controller } = load(true);
  controller.hasCartTarget = true;
  controller.cartTarget = { dataset: { step: 'cart' } };
  controller.showOutcome({ detail: { checkout: { status: 'paid', reference: 'a' } } });
  assert.equal(controller.cartTarget.dataset.step, 'cart');
  controller.showOutcome({ detail: { checkout: { status: 'declined', reference: 'b' } } });
  assert.equal(controller.cartTarget.dataset.step, 'checkout');
  controller.backToCart();
  controller.showOutcome({ detail: { checkout: { status: 'declined', reference: 'b' } } });
  assert.equal(controller.cartTarget.dataset.step, 'cart');
  controller.showOutcome({ detail: { checkout: null } });
  assert.equal(controller.cartTarget.dataset.step, 'cart');
});
