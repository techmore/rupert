import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/javascript/controllers/team_chat_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.TeamChat = class');
const context = { URL, document: { hidden: false } };
vm.createContext(context);
vm.runInContext(source, context);
const Chat = context.TeamChat;
const plain = (value) => JSON.parse(JSON.stringify(value));
const types = (parts) => plain(parts.map((part) => part.type));

test('paragraphs and lists', () => {
  const blocks = Chat.parseBlocks('Sales were up.\nCard was most of it.\n\n- Shopify: $120\n- Square: $80\n\n1. Open Sales\n2. Pick a day');
  assert.deepEqual(plain(blocks.map((block) => block.type)), ['p', 'ul', 'ol']);
  assert.equal(blocks[0].lines.length, 2);
  assert.deepEqual(plain(blocks[1].items), ['Shopify: $120', 'Square: $80']);
});

test('inline marks, mentions and links', () => {
  assert.deepEqual(types(Chat.parseInline('Ask **@rupert** or `sync`')), ['text', 'bold', 'text', 'code']);
  assert.deepEqual(types(Chat.parseInline('hey @rupert, sales?')), ['text', 'mention', 'text']);
  assert.deepEqual(types(Chat.parseInline('mail me@rupert.com')), ['text']);
  const same = Chat.parseInline('Open [Timesheets](/people/timesheets).');
  assert.equal(same[1].type, 'link');
  assert.equal(same[1].href, '/people/timesheets');
  assert.equal(same[1].external, undefined);
  const outside = Chat.parseInline('See https://example.com/a.');
  assert.equal(outside[1].href, 'https://example.com/a');
  assert.equal(outside[1].external, true);
  assert.equal(outside[2].text, '.');
});

test('a label never hides an outside address, and unsafe schemes stay text', () => {
  for (const hostile of ['[x](https://evil.example)', '[x](//evil.example/a)', '[x](javascript:alert(1))', 'javascript:alert(1)']) {
    for (const part of Chat.parseInline(hostile).filter((candidate) => candidate.type === 'link')) {
      // Same-site links may carry a label; an outside link always shows its own address.
      assert.ok(part.href.startsWith('/') ? !part.href.startsWith('//') : part.href === new URL(part.text).href, hostile);
    }
  }
  assert.equal(Chat.safeUrl('https://user:pw@evil.example'), null);
  assert.equal(Chat.safeUrl('javascript:alert(1)'), null);
});

test('local model @agents are highlighted as mentions when listed', () => {
  assert.deepEqual(types(Chat.parseInline('hey @gemma and @rupert', [], ['rupert', 'gemma'])), ['text', 'mention', 'text', 'mention']);
  assert.deepEqual(types(Chat.parseInline('hey @gemma', [])), ['text'], 'not a mention unless the agent exists');
  assert.deepEqual(types(Chat.parseInline('mail me@gemma.com', [], ['rupert', 'gemma'])), ['text']);
});

async function pollChange(before, after) {
  const chat = new Chat();
  chat.byId = new Map([[before.id, before]]);
  chat.since = '2026-10-22T12:00:00.000000Z';
  chat.query = () => '/messages';
  chat.fetchJson = async () => ({ now: '2026-10-22T12:00:01.000000Z', messages: [after] });
  chat.renderRooms = chat.setPins = chat.renderTyping = chat.applyPresence = () => {};
  const rendered = [];
  chat.render = () => rendered.push(chat.byId.get(after.id));
  await chat.poll();
  return rendered;
}

test('polling renders an action decision even when text and timestamps are unchanged', async () => {
  const before = { id: 1, body: 'Proposed.', status: 'pending', updated_at: '2026-10-22T12:00:00Z',
    actions: [{ id: 'a', status: 'proposed' }] };
  const after = { ...before, actions: [{ id: 'a', status: 'done', result: 'Created task #1' }] };
  const rendered = await pollChange(before, after);
  assert.equal(rendered.length, 1);
  assert.equal(rendered[0].actions[0].status, 'done');
});

test('polling renders completion even when the final text was already streamed', async () => {
  const before = { id: 1, body: 'Ready for approval.', status: 'pending', activity: null, updated_at: '2026-10-22T12:00:00Z' };
  const rendered = await pollChange(before, { ...before, status: 'done' });
  assert.equal(rendered.length, 1);
  assert.equal(rendered[0].status, 'done');
});

test('after a finished bot answer the bubbles become its Next questions, and go back otherwise', () => {
  const node = (tag) => ({ tag, children: [], dataset: {}, attrs: {}, className: '', textContent: '',
    setAttribute(name, value) { this.attrs[name] = value }, replaceChildren(...kids) { this.children = kids } });
  context.document.createElement = node;
  const row = node('div');
  const original = node('button');
  original.textContent = 'How did yesterday go?';
  row.children = [original];
  row.dataset.prefix = '@rupert ';
  const chat = Object.create(Chat.prototype);
  Object.defineProperty(chat, 'hasSuggestionsTarget', { value: true });
  Object.defineProperty(chat, 'suggestionsTarget', { value: row });
  const answer = { id: 7, kind: 'assistant', status: 'done', follow_ups: ['Which source sold the most?'] };

  chat.renderFollowUps([{ id: 6, kind: 'person' }, answer]);
  assert.equal(row.children[0].textContent, 'Next:');
  assert.equal(row.children[1].textContent, 'Which source sold the most?');
  assert.equal(row.children[1].dataset.text, '@rupert Which source sold the most?');
  assert.equal(row.attrs['aria-label'], 'Suggested next questions');

  chat.renderFollowUps([answer, { id: 8, kind: 'assistant', status: 'pending' }]);
  assert.equal(row.children.length, 1);
  assert.equal(row.children[0], original);
});

test('a checked bot answer gets a quiet text note, with the tick hidden from screen readers', () => {
  const node = (tag) => ({ tag, children: [], attrs: {}, className: '', textContent: '', title: '',
    setAttribute(name, value) { this.attrs[name] = value }, append(...kids) { this.children.push(...kids) } });
  context.document.createElement = node;
  const note = Object.create(Chat.prototype).checkedNode();
  assert.equal(note.className, 'chat-checked');
  assert.equal(note.attrs.role, 'note');
  assert.equal(note.children[0].attrs['aria-hidden'], 'true');
  assert.equal(note.children[0].textContent, '✓');
  assert.equal(note.children[1].textContent, 'Figures checked against Rupert');
  assert.match(note.title, /All of them were found/);
});

test('side panel: Rupert pages open in panel mode; chat pages and other sites stay normal links', () => {
  assert.equal(Chat.panelPath('/reports/sales?from=2026-10-01', 'https://rupert.test'), '/reports/sales?from=2026-10-01&panel=1');
  assert.equal(Chat.panelPath('/chat/admins', 'https://rupert.test'), null);
  assert.equal(Chat.panelPath('//evil.test/x', 'https://rupert.test'), null);
  assert.equal(Chat.panelPath('https://evil.test/x', 'https://rupert.test'), null);
});

test('side panel: CSV files become rows, with quoted commas and quotes', () => {
  assert.deepEqual(plain(Chat.parseCsv('\uFEFFItem,Note\r\n"Tea, green","He said ""hi"""\r\nMug,')),
    [['Item', 'Note'], ['Tea, green', 'He said "hi"'], ['Mug', '']]);
  assert.equal(Chat.parseCsv('a\nb\nc\n', 2).length, 2);
});

test('side panel: charts draw one bar per row and series, labels from the first column', () => {
  const spec = Chat.chartSpec(['Day', 'Store', 'Online'], [['Mon', '$10.00', 5], ['Tue', 20, '7']], 'bar_chart');
  assert.deepEqual(plain(spec.series), ['Store', 'Online']);
  assert.equal(spec.marks.filter((mark) => mark.tag === 'rect').length, 4);
  assert.equal(Chat.chartSpec(['Day', 'Sales'], [['Mon', 1], ['Tue', 2]], 'line_chart').marks.filter((mark) => mark.tag === 'polyline').length, 1);
  assert.equal(Chat.numberOf('−$1,200.50'), -1200.5);
  assert.equal(Chat.numberOf('n/a'), null);
});

test('side panel: missing chart values are not plotted as zero or joined across gaps', () => {
  const rows = [['Mon', 10], ['Tue', null], ['Wed', 0], ['Thu', 'unknown'], ['Fri', 5]];
  const bars = Chat.chartSpec(['Day', 'Sales'], rows, 'bar_chart');
  assert.equal(bars.marks.filter((mark) => mark.tag === 'rect').length, 3);
  const lines = Chat.chartSpec(['Day', 'Sales'], rows, 'line_chart');
  assert.equal(lines.marks.filter((mark) => mark.tag === 'polyline').length, 0);
  assert.equal(lines.marks.filter((mark) => mark.tag === 'circle').length, 3);
});

test('side panel: series and row selection preserve values and clamp the snapshot range', () => {
  const rows = [['Mon', 10, null], ['Tue', 20, 3], ['Wed', 30, 0]];
  const chosen = Chat.viewSelection(['Day', 'Store', 'Online'], rows, '2', '2', '8');
  assert.deepEqual(plain(chosen), { first: 2, last: 3, columns: ['Day', 'Online'], rows: [['Tue', 3], ['Wed', 0]] });
  assert.deepEqual(rows, [['Mon', 10, null], ['Tue', 20, 3], ['Wed', 30, 0]]);
  assert.deepEqual(plain(Chat.viewSelection(['Day', 'Store'], rows, 'all', '3', '1').rows), [['Wed', 30]]);
});

test('side panel: controls update the displayed chart and table', () => {
  const node = (tag) => ({ tag, children: [], attrs: {}, value: '', listeners: {},
    setAttribute(name, value) { this.attrs[name] = value },
    append(...kids) { this.children.push(...kids); if (this.tag === 'select' && !this.value && kids[0]?.tag === 'option') this.value = kids[0].value },
    replaceChildren(...kids) { this.children = kids }, addEventListener(name, fn) { this.listeners[name] = fn } });
  context.document.createElement = node;
  const chat = Object.create(Chat.prototype);
  chat.chartNode = (view) => ({ tag: 'chart', view });
  chat.tableNode = (columns, rows) => ({ tag: 'table', columns, rows });
  const wrap = chat.adjustableViewNode({ kind: 'bar_chart', columns: ['Day', 'Sales', 'Orders'], rows: [['Mon', 10, 1], ['Tue', 20, 2]] });
  const controls = wrap.children[0].children.map((label) => label.children[0]);
  controls[0].value = 'line_chart'; controls[1].value = '2'; controls[2].value = '2';
  controls[2].listeners.change();
  const result = wrap.children[2];
  assert.equal(result.children[0].view.kind, 'line_chart');
  assert.deepEqual(plain(result.children[1].rows), [['Tue', 2]]);
});

test('voice reply is played once when the saved assistant message finishes', () => {
  const chat = new Chat();
  chat.byId = new Map();
  chat.voiceReplyIds = new Set([42]);
  const played = [];
  chat.playVoice = (message) => played.push(message.id);
  chat.merge([{ id: 42, kind: 'assistant', status: 'pending', body: '', updated_at: 'a' }]);
  chat.merge([{ id: 42, kind: 'assistant', status: 'done', body: 'Hello', updated_at: 'b' }]);
  chat.merge([{ id: 42, kind: 'assistant', status: 'done', body: 'Hello', updated_at: 'b' }]);
  assert.deepEqual(played, [42]);
  assert.equal(chat.byId.get(42).body, 'Hello');
});

test('voice transcription is sent through the normal chat request', async () => {
  context.FormData = FormData;
  context.Blob = Blob;
  context.clearTimeout = clearTimeout;
  const chat = new Chat();
  chat.element = { isConnected: true };
  let stopped = 0;
  chat.voiceStream = { getTracks: () => [{ stop: () => { stopped += 1; } }] };
  chat.voiceTarget = { textContent: '', disabled: false, setAttribute() {} };
  chat.voiceChunks = [new Blob(['audio'])];
  chat.recorder = { mimeType: 'audio/webm' };
  chat.voiceUrlValue = '/chat/admins/voice/transcribe';
  chat.inputTarget = { value: '' };
  chat.sendTarget = {};
  chat.directValue = false;
  chat.input = () => {};
  chat.fetchJson = async (url, options) => {
    assert.equal(url, '/chat/admins/voice/transcribe');
    assert.equal(options.method, 'POST');
    return { text: 'Hello Rupert' };
  };
  let sent;
  chat.post = async (field, button, parent, voice) => { sent = [field.value, parent, voice]; };
  await chat.finishVoice();
  assert.deepEqual(sent, ['@rupert Hello Rupert', null, true]);
  assert.equal(stopped, 1);
  assert.equal(chat.voiceTarget.disabled, false);
});

test('voice transcription errors do not submit a message', async () => {
  context.FormData = FormData;
  context.Blob = Blob;
  context.clearTimeout = clearTimeout;
  const chat = new Chat();
  chat.element = { isConnected: true };
  chat.voiceStream = { getTracks: () => [] };
  chat.voiceTarget = { textContent: '', disabled: false, setAttribute() {} };
  chat.voiceChunks = [new Blob(['audio'])];
  chat.recorder = { mimeType: 'audio/webm' };
  chat.fetchJson = async () => null;
  chat.post = async () => { throw new Error('should not post'); };
  await chat.finishVoice();
  assert.equal(chat.voiceTarget.disabled, false);
});

test('a channel voice handoff plays the private answer, not the channel redirect', async () => {
  const chat = new Chat();
  chat.element = { isConnected: true };
  chat.urlValue = '/chat/admins/messages';
  chat.voiceHandoffTimers = new Set();
  context.fetch = async (url) => {
    assert.equal(url, '/chat/admins/messages/12/voice_handoff');
    return { ok: true, json: async () => ({ status: 'done', speech_url: '/chat/private/messages/34/speech' }) };
  };
  let played;
  chat.playVoice = async (message, url) => { played = [message, url]; };
  await chat.followVoiceHandoff(12);
  assert.deepEqual(played, [null, '/chat/private/messages/34/speech']);
  assert.equal(chat.voiceHandoffTimers.size, 0);
});
