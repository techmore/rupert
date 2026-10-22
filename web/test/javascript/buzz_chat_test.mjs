import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/javascript/controllers/buzz_chat_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.BuzzChat = class');
const context = { URL };
vm.createContext(context);
vm.runInContext(source, context);
const Chat = context.BuzzChat;
// Values built inside the vm context are from another realm; compare them as plain data.
const plain = (value) => JSON.parse(JSON.stringify(value));

test('bold, code and links are parsed without any HTML', () => {
  const parts = Chat.parseLine('See **this** and `that` at https://example.com/a?b=1.');
  assert.deepEqual(plain(parts.map((part) => part.type)), ['text', 'bold', 'text', 'code', 'text', 'link', 'text']);
  assert.equal(parts[5].href, 'https://example.com/a?b=1');
  assert.equal(parts[5].text, 'https://example.com/a?b=1');
  assert.equal(parts[6].text, '.');
});

test('only http and https links become links', () => {
  for (const hostile of ['javascript:alert(1)', 'data:text/html,hi', 'ftp://example.com/x', 'file:///etc/passwd']) {
    assert.ok(Chat.parseLine(hostile).every((part) => part.type === 'text'), hostile);
  }
  assert.equal(Chat.parseLine('https://user:pass@example.com/').every((part) => part.type === 'text'), true);
});

test('markup in a message stays plain text', () => {
  const parts = Chat.parseLine('<img src=x onerror=alert(1)> and <b>bold</b> [x](javascript:alert(1))');
  assert.equal(parts.length, 1);
  assert.equal(parts[0].type, 'text');
  assert.equal(parts[0].text, '<img src=x onerror=alert(1)> and <b>bold</b> [x](javascript:alert(1))');
});

test('trailing punctuation is not part of a link but balanced brackets are', () => {
  const wrapped = Chat.parseLine('(see https://example.com/x)');
  assert.equal(wrapped.find((part) => part.type === 'link').href, 'https://example.com/x');
  const wiki = Chat.parseLine('https://en.wikipedia.org/wiki/Rupert_(name)');
  assert.equal(wiki.find((part) => part.type === 'link').href, 'https://en.wikipedia.org/wiki/Rupert_(name)');
});

test('the @mention being typed is found just before the caret', () => {
  assert.deepEqual(plain(Chat.mentionQuery('hello @al', 9)), { query: 'al', start: 6 });
  assert.deepEqual(plain(Chat.mentionQuery('@', 1)), { query: '', start: 0 });
  assert.equal(Chat.mentionQuery('mail me at a@b.com', 18), null, 'an @ inside a word is not a mention');
  assert.equal(Chat.mentionQuery('hello @alice and', 16), null, 'a finished word is not being typed');
  assert.deepEqual(plain(Chat.mentionQuery('hi @bo then @al', 15)), { query: 'al', start: 12 });
});

test('members are filtered by name with the agent and prefix matches first', () => {
  const members = [
    { name: 'Alice', pubkey: 'a' }, { name: 'Malik', pubkey: 'm' }, { name: 'Rupert', pubkey: 'r', agent: true }, { name: 'Alan', pubkey: 'n' }
  ];
  assert.deepEqual(plain(Chat.filterMembers(members, 'al').map((m) => m.name)), ['Alan', 'Alice', 'Malik']);
  assert.deepEqual(plain(Chat.filterMembers(members, 'ru').map((m) => m.name)), ['Rupert']);
  assert.equal(Chat.filterMembers(members, '').length, 4);
  assert.equal(Chat.filterMembers(members, 'zzz').length, 0);
});

test('only mentions whose @name is still in the text are sent', () => {
  const picked = new Map([['Alice A', 'k1'], ['Bob', 'k2'], ['Rupert', 'k3']]);
  assert.deepEqual(plain(Chat.mentionedKeys('hi @Alice A and @Rupert', picked)), ['k1', 'k3']);
  assert.deepEqual(plain(Chat.mentionedKeys('I removed them', picked)), []);
});

test('cursors order by time first, then id', () => {
  assert.ok(Chat.compareCursor('100:aa', '200:00') < 0);
  assert.ok(Chat.compareCursor('200:bb', '200:aa') > 0);
  assert.equal(Chat.compareCursor('200:aa', '200:aa'), 0);
});
