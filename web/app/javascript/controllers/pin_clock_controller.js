import { Controller } from '@hotwired/stimulus'

// The PIN clock pad (shared/_pin_clock). Type the PIN: the fourth digit sends the punch. Clocked
// out → clocked in, one confirmation line, closes itself. Clocked in → Clock out / Break / Meal.
// Forgotten clock-out → pick the real time, then today's clock-in starts.
//
// Offline: when the request cannot reach the server on a trusted store device, the punch is kept
// in localStorage with its request_token (the server dedupes on it) and the time it was typed, and
// replayed when the browser is back online. Nothing is queued on an untrusted device.

const QUEUE_KEY = 'rupert.pinClock.queue'

export function queuedPunches(storage = globalThis.localStorage) {
  try {
    const raw = storage?.getItem(QUEUE_KEY)
    const list = raw ? JSON.parse(raw) : []
    return Array.isArray(list) ? list : []
  } catch {
    return []
  }
}

export function enqueuePunch(punch, storage = globalThis.localStorage) {
  const list = queuedPunches(storage).filter(item => item.request_token !== punch.request_token)
  list.push(punch)
  storage?.setItem(QUEUE_KEY, JSON.stringify(list.slice(-50)))
  return list.length
}

export function dequeuePunch(token, storage = globalThis.localStorage) {
  const list = queuedPunches(storage).filter(item => item.request_token !== token)
  if (list.length) storage?.setItem(QUEUE_KEY, JSON.stringify(list))
  else storage?.removeItem(QUEUE_KEY)
  return list.length
}

// A punch that can be replayed later: only the definite actions (a 'punch' toggle depends on state).
export function queueable(action) {
  return ['punch', 'clock_in', 'clock_out', 'break', 'meal', 'end_break'].includes(action)
}

export function requestToken() {
  const bytes = new Uint8Array(16)
  if (globalThis.crypto?.getRandomValues) globalThis.crypto.getRandomValues(bytes)
  else for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256)
  return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('')
}

export default class extends Controller {
  static targets = ['root', 'title', 'message', 'pad', 'dots', 'input', 'options', 'since', 'breakButton', 'mealButton', 'endBreakButton',
    'fix', 'fixOptions', 'customEnd', 'setup', 'setupWho', 'setupNumber', 'setupWorker', 'setupPin', 'setupConfirm',
    'confirm', 'confirmName', 'confirmLine', 'queue', 'dot']
  static values = { url: String, setupUrl: String, workersUrl: String, length: { type: Number, default: 4 }, location: String, register: String,
    trusted: Boolean, kiosk: Boolean, strings: Object }

  connect() {
    this.pin = ''
    this.token = requestToken()
    this.onlineHandler = () => this.replayQueue()
    window.addEventListener('online', this.onlineHandler)
    this.replayQueue()
    if (this.kioskValue) this.reset()
  }

  disconnect() {
    window.removeEventListener('online', this.onlineHandler)
    clearTimeout(this.dismissTimer)
  }

  // ---- opening and closing (POS dialog) ------------------------------------------------------

  open() {
    this.reset()
    if (this.rootTarget.tagName === 'DIALOG' && !this.rootTarget.open) this.rootTarget.showModal()
    this.focusInput()
  }

  close() {
    if (this.rootTarget.tagName === 'DIALOG' && this.rootTarget.open) this.rootTarget.close()
  }

  closed() {
    clearTimeout(this.dismissTimer)
    this.reset()
  }

  // Done / Cancel: close the dialog on the POS strip, start over on the kiosk.
  finish() {
    if (this.kioskValue) this.reset()
    else this.close()
  }

  backdropClose(event) {
    if (event.target === event.currentTarget) this.close()
  }

  keydown(event) {
    if (event.key === 'Escape') { event.preventDefault(); this.close() }
  }

  // ---- the pad --------------------------------------------------------------------------------

  reset() {
    clearTimeout(this.dismissTimer)
    this.pin = ''
    this.token = requestToken()
    this.pending = false
    this.show('pad')
    this.titleTarget.textContent = this.titleTarget.dataset.default || (this.titleTarget.dataset.default = this.titleTarget.textContent)
    this.setMessage(this.messageTarget.dataset.default || (this.messageTarget.dataset.default = this.messageTarget.textContent))
    this.renderDots()
    if (this.hasInputTarget) this.inputTarget.value = ''
    this.focusInput()
  }

  key(event) {
    this.append(event.currentTarget.dataset.digit)
  }

  typed() {
    this.pin = this.inputTarget.value.replace(/\D/g, '').slice(0, this.lengthValue)
    this.inputTarget.value = this.pin
    this.renderDots()
    if (this.pin.length === this.lengthValue) this.punch('punch')
  }

  append(digit) {
    if (this.pending || this.pin.length >= this.lengthValue) return
    this.pin += digit
    if (this.hasInputTarget) this.inputTarget.value = this.pin
    this.renderDots()
    if (this.pin.length === this.lengthValue) this.punch('punch')
  }

  backspace() {
    this.pin = this.pin.slice(0, -1)
    if (this.hasInputTarget) this.inputTarget.value = this.pin
    this.renderDots()
  }

  renderDots() {
    Array.from(this.dotsTarget.children).forEach((dot, index) => dot.classList.toggle('pin-clock-dot-on', index < this.pin.length))
  }

  // Clock out / Break / Meal / End break with the PIN already typed.
  act(event) {
    this.punch(event.currentTarget.dataset.clockAction)
  }

  fixWith(event) {
    this.punch('fix_and_clock_in', { proposed_ended_at: event.currentTarget.dataset.at })
  }

  fixCustom() {
    const value = this.customEndTarget.value
    if (!value) { this.customEndTarget.focus(); return }
    this.punch('fix_and_clock_in', { proposed_ended_at: value })
  }

  async punch(action, extra = {}) {
    if (this.pending) return
    this.pending = true
    const body = { pin: this.pin, clock_action: action, request_token: this.token, location_id: this.locationValue || undefined,
      register_name: this.registerValue || undefined, kiosk: this.kioskValue || undefined, ...extra }
    try {
      const response = await this.post(this.urlValue, body)
      const data = await response.json().catch(() => ({}))
      this.pending = false
      if (!response.ok || !data.ok) {
        if (response.status === 503 && data.retry) return this.setMessage(data.error, 'warn')
        this.shake(data.error || this.stringsValue.wrong)
        return
      }
      this.render(data)
    } catch {
      this.pending = false
      if (this.trustedValue && queueable(action)) {
        enqueuePunch({ ...body, punched_at: new Date().toISOString() })
        this.renderQueue()
        this.showConfirm('', this.stringsValue.offline)
      } else {
        this.setMessage(this.stringsValue.busy, 'warn')
      }
    }
  }

  render(data) {
    switch (data.event) {
      case 'already_in': {
        this.titleTarget.textContent = data.message
        this.setMessage('')
        const shift = data.shift || {}
        this.sinceTarget.textContent = shift.on_break
          ? (shift.break_kind === 'meal' ? this.stringsValue.on_meal : this.stringsValue.on_break).replace('%{minutes}', shift.break_minutes)
          : this.stringsValue.since.replace('%{time}', shift.started_label || '')
        this.breakButtonTarget.hidden = !!shift.on_break
        this.mealButtonTarget.hidden = !!shift.on_break
        this.endBreakButtonTarget.hidden = !shift.on_break
        this.show('options')
        break
      }
      case 'needs_fix': {
        this.titleTarget.textContent = data.message
        this.setMessage('')
        this.fixOptionsTarget.replaceChildren(...(data.fix_options || []).map(option => {
          const button = document.createElement('button')
          button.type = 'button'
          button.className = 'btn-ghost btn-lg pin-clock-option'
          button.textContent = option.label
          button.dataset.at = option.at
          button.dataset.action = 'pin-clock#fixWith'
          return button
        }))
        this.show('fix')
        break
      }
      default:
        this.showConfirm(data.first_name, data.message)
        if (data.own && this.hasDotTarget) this.dotTarget.dataset.state = data.state
        this.element.dispatchEvent(new CustomEvent('pin-clock:punched', { bubbles: true, detail: data }))
    }
  }

  showConfirm(name, line) {
    this.confirmNameTarget.textContent = name || ''
    this.confirmLineTarget.textContent = line
    this.titleTarget.textContent = ''
    this.setMessage('')
    this.show('confirm')
    this.token = requestToken()
    this.pin = ''
    clearTimeout(this.dismissTimer)
    this.dismissTimer = setTimeout(() => (this.kioskValue ? this.reset() : this.close()), 2500)
  }

  shake(message) {
    this.setMessage(message, 'error')
    this.rootTarget.classList.remove('pin-clock-shake')
    void this.rootTarget.offsetWidth
    this.rootTarget.classList.add('pin-clock-shake')
    this.pin = ''
    if (this.hasInputTarget) this.inputTarget.value = ''
    this.renderDots()
    this.focusInput()
  }

  // ---- first use: choose a PIN ----------------------------------------------------------------

  async startSetup() {
    this.titleTarget.textContent = this.stringsValue.setup_title || ''
    this.setMessage('')
    this.show('setup')
    try {
      const response = await fetch(this.workersUrlValue, { headers: { Accept: 'application/json' }, credentials: 'same-origin' })
      const data = response.ok ? await response.json() : { data: [] }
      const options = (data.data || []).map(worker => {
        const option = document.createElement('option')
        option.value = worker.id
        option.textContent = worker.number ? `${worker.name} · ${worker.number}` : worker.name
        return option
      })
      this.setupWorkerTarget.replaceChildren(new Option('', ''), ...options)
      // One choice means the signed-in person themselves: preselect and hide the question.
      if (options.length === 1) { this.setupWorkerTarget.value = options[0].value; this.setupWhoTarget.hidden = true }
      else this.setupWhoTarget.hidden = false
    } catch {
      this.setupWhoTarget.hidden = false
    }
    this.setupPinTarget.focus()
  }

  async saveSetup(event) {
    event.preventDefault()
    const body = { pin: this.setupPinTarget.value, pin_confirmation: this.setupConfirmTarget.value,
      employee_id: this.setupWorkerTarget.value || undefined, employee_number: this.setupNumberTarget.value || undefined,
      kiosk: this.kioskValue || undefined }
    try {
      const response = await this.post(this.setupUrlValue, body)
      const data = await response.json().catch(() => ({}))
      if (!response.ok || !data.ok) return this.setMessage(data.error || this.stringsValue.wrong, 'error')
      this.setupPinTarget.value = ''
      this.setupConfirmTarget.value = ''
      this.reset()
      this.setMessage(data.message, 'ok')
    } catch {
      this.setMessage(this.stringsValue.busy, 'warn')
    }
  }

  // ---- offline queue --------------------------------------------------------------------------

  async replayQueue() {
    if (!navigator.onLine) return this.renderQueue()
    for (const punch of queuedPunches()) {
      try {
        const response = await this.post(this.urlValue, punch)
        if (response.ok || response.status === 422) dequeuePunch(punch.request_token)
        else break
      } catch {
        break
      }
    }
    this.renderQueue()
  }

  renderQueue() {
    if (!this.hasQueueTarget) return
    const count = queuedPunches().length
    this.queueTarget.hidden = count === 0
    this.queueTarget.textContent = count ? `${count} · ${this.stringsValue.offline}` : ''
  }

  // ---- helpers --------------------------------------------------------------------------------

  post(url, body) {
    return fetch(url, {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '' },
      body: JSON.stringify(body)
    })
  }

  show(panel) {
    for (const name of ['pad', 'options', 'fix', 'setup', 'confirm']) {
      const target = this[`${name}Target`]
      if (target) target.hidden = name !== panel
    }
  }

  setMessage(text, tone = '') {
    this.messageTarget.textContent = text || ''
    this.messageTarget.dataset.tone = tone
  }

  focusInput() {
    if (this.hasInputTarget && window.matchMedia('(pointer: fine)').matches) this.inputTarget.focus()
  }
}
