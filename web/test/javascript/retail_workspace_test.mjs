import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const element = () => ({ dataset: {}, children: [], setAttribute(name, value) { this[name] = value; }, append(...children) { this.children.push(...children); }, replaceChildren(...children) { this.children = children; } });
const context = { document: { createElement: element }, Intl };
vm.createContext(context);
for (const [file, name] of [['pos_cart', 'Cart'], ['pos_checkout', 'Checkout']]) {
  const source = readFileSync(new URL(`../../app/javascript/controllers/${file}_controller.js`, import.meta.url), 'utf8')
    .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
    .replace('export default class', `globalThis.${name} = class`);
  vm.runInContext(`{${source}}`, context);
}
const cart = new context.Cart();
cart.itemsTarget = element();
cart.hasCountTarget = true;
cart.countTargets = [{}, {}];
cart.cart = new Map([['tea', 2], ['coffee', 3]]);
cart.render([]);
assert.equal(cart.countTargets[0].textContent, 5);
assert.equal(cart.countTargets[1].textContent, 5);
assert.equal(cart.itemsTarget.children.length, 2);
cart.cart.clear();
cart.render([]);
assert.equal(cart.countTargets[0].textContent, 0);
cart.hasCountTarget = false;
cart.render([]); // Existing preview and embedded demos need no counter target.
const checkout = new context.Checkout();
checkout.tenderTarget = { value: 'cash' };
checkout.tenderButtonTargets = [{ dataset: { tender: 'cash' }, setAttribute() {} }, { dataset: { tender: 'card', available: 'false' }, setAttribute() {} }];
checkout.cashFieldsTarget = {};
checkout.cashTarget = {};
checkout.submitTarget = {};
checkout.demoValue = false;
checkout.tenderChanged();
assert.equal(checkout.submitTarget.value, 'Complete cash sale');
assert.equal(checkout.submitTarget.disabled, false);
assert.equal(checkout.cashTarget.required, true);
checkout.tenderTarget.value = 'card';
checkout.tenderChanged();
assert.equal(checkout.submitTarget.value, 'Send card checkout to customer screen');
assert.equal(checkout.submitTarget.disabled, true); // card not set up for this store
assert.equal(checkout.cashFieldsTarget.hidden, true);
assert.equal(checkout.cashTarget.required, false);
checkout.demoValue = true;
checkout.tenderChanged();
assert.equal(checkout.submitTarget.value, 'Send demo card checkout');
// Card (A920): recorded like cash after the terminal approves; no cash field, no gateway step.
checkout.demoValue = false;
checkout.hasA920FieldsTarget = true;
checkout.a920FieldsTarget = { hidden: true };
checkout.tenderButtonTargets.push({ dataset: { tender: 'card_a920', available: 'true' }, setAttribute() {} });
checkout.tenderTarget.value = 'card_a920';
checkout.tenderChanged();
assert.equal(checkout.submitTarget.value, 'Record A920 card sale');
assert.equal(checkout.submitTarget.disabled, false);
assert.equal(checkout.cashFieldsTarget.hidden, true);
assert.equal(checkout.cashTarget.required, false);
assert.equal(checkout.a920FieldsTarget.hidden, false);
checkout.demoValue = true;
checkout.tenderChanged();
assert.equal(checkout.submitTarget.value, 'Run demo A920 card sale');
checkout.tenderTarget.value = 'cash';
checkout.tenderChanged();
assert.equal(checkout.a920FieldsTarget.hidden, true);
checkout.statusTarget = {};
checkout.resultTarget = element();
checkout.urlValue = '/pos_checkouts';
checkout.renderCheckout({ id: 1, reference: 'r1', status: 'paid', tender: 'card_a920', total_cents: 1166 });
assert.equal(checkout.statusTarget.textContent, 'Paid · $11.66 · Card (A920), no gateway charge');
console.log('Retail cart counters sum units; checkout labels track tender and demo state without submitting.');
