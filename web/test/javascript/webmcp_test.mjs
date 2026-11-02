import assert from 'node:assert/strict';
import { test } from 'node:test';

// No `window` in node, so importing does not start anything on its own.
const webmcp = await import(new URL('../../app/javascript/lib/webmcp.js', import.meta.url));
const { createWebMcp, modelContextOf, readConfig, confirmationMessage, ELEMENT_ID } = webmcp;

// A model context that records what the page registers, honouring the AbortSignal like the draft spec.
class FakeModelContext {
  constructor() { this.tools = new Map(); }
  async registerTool(tool, { signal } = {}) {
    if (this.tools.has(tool.name)) throw new Error('InvalidStateError');
    this.tools.set(tool.name, tool);
    signal?.addEventListener('abort', () => this.tools.delete(tool.name), { once: true });
  }
  names() { return [...this.tools.keys()].sort(); }
}

const appTools = (names, extra = {}) => names.map((name) => ({
  name, title: name, description: `${name} tool`, inputSchema: { type: 'object', properties: {} },
  annotations: { readOnlyHint: true }, confirm: false, ...(extra[name] || {}),
}));

function page({ config, context, contextOn = 'document', tools = [] }) {
  const calls = [];
  const listeners = {};
  const element = { textContent: config ? JSON.stringify(config) : '' };
  const document = {
    getElementById: (id) => (id === ELEMENT_ID && element.textContent ? element : null),
    querySelector: (selector) => (selector === 'meta[name="csrf-token"]' ? { getAttribute: () => 'csrf-123' } : null),
    addEventListener: (type, fn) => { listeners[type] = fn; },
  };
  const win = { document, navigator: {} };
  if (context) (contextOn === 'document' ? document : win.navigator).modelContext = context;
  const state = { tools, key: 'k1', posts: [] };
  const fetchImpl = async (url, options = {}) => {
    calls.push({ url, options });
    if (!options.method) return { ok: true, status: 200, json: async () => ({ key: state.key, endpoint: '/webmcp/tools', tools: state.tools }) };
    const body = JSON.parse(options.body);
    state.posts.push({ url, body, headers: options.headers });
    const preview = body.arguments.dry_run ? 'Dry run: would create task “Restock”.' : 'done';
    return { ok: true, status: 200, json: async () => ({ content: [{ type: 'text', text: preview }], isError: false }) };
  };
  return { win, element, calls, state, fetchImpl, setConfig: (next) => { element.textContent = next ? JSON.stringify(next) : ''; } };
}

const APP = { mode: 'app', key: 'k1', endpoint: '/webmcp/tools' };

test('does nothing at all when the browser has no model context', async () => {
  const p = page({ config: APP });
  const instance = createWebMcp(p.win, { fetchImpl: p.fetchImpl, confirmImpl: () => true });
  assert.equal(await instance.sync(), 'unsupported');
  assert.equal(p.calls.length, 0, 'no request is made without the API');
  assert.equal(modelContextOf(p.win), null);
});

test('ignores a model context without registerTool', async () => {
  const p = page({ config: APP, context: { provideContext() {} } });
  assert.equal(await createWebMcp(p.win, { fetchImpl: p.fetchImpl }).sync(), 'unsupported');
  assert.equal(p.calls.length, 0);
});

test('public pages register the embedded read-only facts without any request', async () => {
  const context = new FakeModelContext();
  const config = { mode: 'public', tools: [{ name: 'get_contact', title: 'Contact', description: 'How to reach us', inputSchema: { type: 'object', properties: {} }, annotations: { readOnlyHint: true }, result: { email: 'sdolbec@rupertpos.com' } }] };
  const p = page({ config, context });
  assert.equal(await createWebMcp(p.win, { fetchImpl: p.fetchImpl }).sync(), 'registered');
  assert.deepEqual(context.names(), ['get_contact']);
  assert.equal(p.calls.length, 0);
  const out = await context.tools.get('get_contact').execute({}, { signal: new AbortController().signal });
  assert.equal(out.structuredContent.email, 'sdolbec@rupertpos.com');
  assert.equal(out.isError, false);
  assert.equal(context.tools.get('get_contact').annotations.readOnlyHint, true);
});

test('signed-in pages register exactly the tools the server lists for this person', async () => {
  const context = new FakeModelContext();
  const p = page({ config: APP, context, tools: appTools(['inventory_search', 'list_alerts']) });
  await createWebMcp(p.win, { fetchImpl: p.fetchImpl }).sync();
  assert.deepEqual(context.names(), ['inventory_search', 'list_alerts']);
  assert.equal(p.calls[0].url, '/webmcp/tools');
  assert.equal(p.calls[0].options.credentials, 'same-origin');
  assert.equal('confirm' in context.tools.get('inventory_search'), false, 'internal flags are not passed to the browser');
});

test('a read tool posts its arguments with the page CSRF token', async () => {
  const context = new FakeModelContext();
  const p = page({ config: APP, context, tools: appTools(['inventory_search']) });
  await createWebMcp(p.win, { fetchImpl: p.fetchImpl }).sync();
  await context.tools.get('inventory_search').execute({ query: 'tea' }, { signal: new AbortController().signal });
  const [post] = p.state.posts;
  assert.equal(post.url, '/webmcp/tools/inventory_search');
  assert.equal(post.headers['X-CSRF-Token'], 'csrf-123');
  assert.deepEqual(post.body, { arguments: { query: 'tea' } });
});

test('a write asks the person first; declining sends nothing that changes data', async () => {
  const context = new FakeModelContext();
  const tools = appTools(['create_task'], { create_task: { confirm: true, annotations: { readOnlyHint: false, consequentialHint: true }, inputSchema: { type: 'object', properties: { title: { type: 'string' }, dry_run: { type: 'boolean' } } } } });
  const p = page({ config: APP, context, tools });
  const asked = [];
  await createWebMcp(p.win, { fetchImpl: p.fetchImpl, confirmImpl: (message) => { asked.push(message); return false; } }).sync();
  const out = await context.tools.get('create_task').execute({ title: 'Restock' }, { signal: new AbortController().signal });
  assert.equal(out.isError, true);
  assert.equal(out.error, 'declined');
  assert.equal(asked.length, 1);
  assert.match(asked[0], /Would create task “Restock”\./, 'the dry-run preview is shown to the person');
  assert.doesNotMatch(asked[0], /Dry run|Nothing was saved/, 'without the preview wording that would confuse the person');
  assert.deepEqual(p.state.posts.map((post) => post.body), [{ arguments: { title: 'Restock', dry_run: true } }]);
});

test('a confirmed write is sent once, marked confirmed', async () => {
  const context = new FakeModelContext();
  const tools = appTools(['create_task'], { create_task: { confirm: true, inputSchema: { type: 'object', properties: { title: { type: 'string' }, dry_run: { type: 'boolean' } } } } });
  const p = page({ config: APP, context, tools });
  await createWebMcp(p.win, { fetchImpl: p.fetchImpl, confirmImpl: async () => true }).sync();
  await context.tools.get('create_task').execute({ title: 'Restock' }, { signal: new AbortController().signal });
  assert.deepEqual(p.state.posts.map((post) => post.body), [
    { arguments: { title: 'Restock', dry_run: true } },
    { arguments: { title: 'Restock' }, confirmed: true },
  ]);
});

test('a confirm dialog that throws counts as declined', async () => {
  const context = new FakeModelContext();
  const p = page({ config: APP, context, tools: appTools(['create_task'], { create_task: { confirm: true } }) });
  await createWebMcp(p.win, { fetchImpl: p.fetchImpl, confirmImpl: () => { throw new Error('blocked'); } }).sync();
  const out = await context.tools.get('create_task').execute({ title: 'X' }, { signal: new AbortController().signal });
  assert.equal(out.error, 'declined');
  assert.equal(p.state.posts.length, 0);
});

test('signing out or a role change swaps the registered tools', async () => {
  const context = new FakeModelContext();
  const p = page({ config: APP, context, tools: appTools(['inventory_search', 'sales_summary']) });
  const instance = createWebMcp(p.win, { fetchImpl: p.fetchImpl });
  await instance.sync();
  assert.deepEqual(context.names(), ['inventory_search', 'sales_summary']);

  assert.equal(await instance.sync(), 'unchanged', 'the same page key does not re-register');

  p.state.tools = appTools(['inventory_search']);
  p.setConfig({ ...APP, key: 'k2' });
  assert.equal(await instance.sync(), 'registered');
  assert.deepEqual(context.names(), ['inventory_search']);

  p.setConfig(null);
  assert.equal(await instance.sync(), 'cleared');
  assert.deepEqual(context.names(), []);
});

test('a denied tool list registers nothing', async () => {
  const context = new FakeModelContext();
  const p = page({ config: APP, context });
  const fetchImpl = async () => ({ ok: false, status: 403, json: async () => ({}) });
  assert.equal(await createWebMcp(p.win, { fetchImpl }).sync(), 'unavailable');
  assert.deepEqual(context.names(), []);
});

test('falls back to navigator.modelContext and handle-based unregistering from early drafts', async () => {
  const registered = new Set();
  const context = { registerTool: async (tool) => { registered.add(tool.name); return { unregister: () => registered.delete(tool.name) }; } };
  const p = page({ config: APP, context, contextOn: 'navigator', tools: appTools(['list_alerts']) });
  const instance = createWebMcp(p.win, { fetchImpl: p.fetchImpl });
  await instance.sync();
  assert.deepEqual([...registered], ['list_alerts']);
  p.setConfig(null);
  await instance.sync();
  assert.deepEqual([...registered], []);
});

test('reads only a well-formed config', () => {
  const doc = (text) => ({ getElementById: () => ({ textContent: text }) });
  assert.equal(readConfig(doc('not json')), null);
  assert.equal(readConfig(doc('{"mode":"other"}')), null);
  assert.equal(readConfig(doc('{"mode":"public","tools":[]}')).mode, 'public');
  assert.equal(readConfig({ getElementById: () => null }), null);
});

test('the confirmation names the change without internal flags', () => {
  const message = confirmationMessage({ title: 'Create a task' }, { title: 'Restock', dry_run: true, idempotency_key: 'x' });
  assert.match(message, /Create a task/);
  assert.match(message, /title: Restock/);
  assert.doesNotMatch(message, /dry run|idempotency/);
});
