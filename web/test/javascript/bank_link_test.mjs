import { readFileSync } from 'node:fs'
import vm from 'node:vm'
import assert from 'node:assert/strict'

const source = readFileSync(new URL('../../app/javascript/controllers/bank_link_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.BankLink = class')

let linkOptions, fetches = [], destination, replacedUrl, destroyed = false
const context = {
  URL,
  window: {
    location: { href: 'https://rupert.example/bank_connection?oauth_state_id=private-state', assign(url) { destination = url } },
    history: { replaceState(_state, _title, url) { replacedUrl = url.href } },
    Plaid: { create(options) { linkOptions = options; return { open() {}, destroy() { destroyed = true } } } }
  },
  document: { querySelector() { return { content: 'csrf-private' } } },
  async fetch(url, options) {
    fetches.push({ url, options })
    return { ok: true, async json() { return url === '/exchange' ? { redirect_url: '/bank_connection' } : { link_token: 'link-private' } } }
  }
}
vm.createContext(context)
vm.runInContext(source, context)
const form = new context.BankLink()
form.statusTarget = { textContent: '' }
form.buttonTargets = [{ disabled: false }]
form.tokenUrlValue = '/token'
form.resumeUrlValue = '/resume'
form.exchangeUrlValue = '/exchange'

// OAuth resumes with the original token and full redirect URI, never a new Link token.
form.resumeValue = true
await form.open()
assert.equal(fetches[0].url, '/resume')
assert.equal(fetches[0].options.method, 'POST')
assert.equal(fetches[0].options.headers['X-CSRF-Token'], 'csrf-private')
assert.equal(linkOptions.receivedRedirectUri, context.window.location.href)
assert.equal(linkOptions.token, 'link-private')
await linkOptions.onSuccess('public-private')
assert.equal(fetches[1].url, '/exchange')
assert.equal(JSON.parse(fetches[1].options.body).public_token, 'public-private')
assert.equal(destination, '/bank_connection')

// Exit restores the connect button and removes consumed OAuth state.
linkOptions.onExit()
assert.equal(form.buttonTargets[0].disabled, false)
assert.equal(form.resumeValue, false)
assert.equal(replacedUrl, 'https://rupert.example/bank_connection')
form.disconnect()
assert.equal(destroyed, true)

// Fresh flow asks the server for a new token and prevents duplicate clicks.
form.connect()
fetches = []
await Promise.all([form.open(), form.open()])
assert.equal(fetches.length, 1)
assert.equal(fetches[0].url, '/token')
assert.equal(linkOptions.receivedRedirectUri, undefined)

// Navigating away invalidates the SDK callback before it can exchange consent.
form.disconnect()
fetches = []
await linkOptions.onSuccess('stale-public-token')
assert.equal(fetches.length, 0)
form.resumeValue = false
form.connect()

// Errors surface only the server's safe message and restore the button.
form.reset()
context.fetch = async () => ({ ok: false, async json() { return { error: 'Consent expired. Reconnect.' } } })
await form.open()
assert.equal(form.statusTarget.textContent, 'Consent expired. Reconnect.')
assert.equal(form.buttonTargets[0].disabled, false)
assert.equal(form.busy, false)
console.log('Bank Link: OAuth resume, exchange, CSRF, cancellation, duplicate clicks and error recovery passed')
