import { Controller } from "@hotwired/stimulus"

// Event register (F70 event mode). Totals come from the event's frozen preset prices and tax
// rate; the server re-prices and re-checks every sale and its receipt is what counts.
//
// Each sale gets a client_sale_id before it is sent, so a retry or a resend from the offline
// queue is recorded once. While offline, a sale the frozen list allows (cash, or card on a
// card-approved item, ID checked) is kept on this device and sent when the connection returns.
// Overrides need the server, so they are never offered offline.
const QUEUE_LIMIT = 200
const SYNC_EVERY_MS = 20000
const REFRESH_EVERY_MS = 60000

export default class extends Controller {
  static targets = ["grid", "lines", "count", "subtotal", "tax", "total", "tender", "cardNote", "idChecked", "cashFields", "cash",
    "issues", "override", "overrideUser", "overridePin", "overrideReason", "submit", "status", "result", "announce",
    "connection", "queueBadge", "refusedBox", "refusedList"]
  static values = { state: Object, salesUrl: String, stateUrl: String, queueKey: String, seller: Boolean }

  connect() {
    if (!this.sellerValue || !this.hasGridTarget) return
    this.cart = new Map()
    this.tender = "cash"
    this.items = new Map((this.stateValue.items || []).map(item => [item.id, item]))
    this.renderGrid()
    this.render()
    this.online = navigator.onLine
    this.onOnline = () => { this.setOnline(true); this.sync() }
    this.onOffline = () => this.setOnline(false)
    window.addEventListener("online", this.onOnline)
    window.addEventListener("offline", this.onOffline)
    this.setOnline(this.online)
    this.syncTimer = setInterval(() => this.sync(), SYNC_EVERY_MS)
    this.refreshTimer = setInterval(() => this.refresh(), REFRESH_EVERY_MS)
    this.sync()
  }

  disconnect() {
    window.removeEventListener("online", this.onOnline)
    window.removeEventListener("offline", this.onOffline)
    clearInterval(this.syncTimer); clearInterval(this.refreshTimer)
  }

  // --- catalog and cart ---

  renderGrid() {
    const tiles = [...this.items.values()].map(item => {
      const tile = document.createElement("button")
      tile.type = "button"; tile.className = "pos-tile event-tile"; tile.dataset.itemId = item.id
      tile.setAttribute("aria-label", `${item.name}, ${this.money(item.price_cents)}${item.card_eligible ? "" : ", cash only"}`)
      tile.addEventListener("click", () => this.add(item.id))
      const name = this.el("span", "pos-tile-name", item.name)
      const category = this.el("span", "pos-tile-variant", item.category || "")
      const foot = this.el("span", "pos-tile-foot")
      foot.append(this.el("span", "pos-tile-price retail-money", this.money(item.price_cents)))
      if (!item.card_eligible) foot.append(this.el("span", "pill-clay", "Cash only"))
      const body = this.el("span", "pos-tile-body"); body.append(name, category, foot)
      tile.append(body)
      return tile
    })
    if (tiles.length === 0) tiles.push(this.el("p", "pos-checkout-hint", "No items are on sale at this event."))
    this.gridTarget.replaceChildren(...tiles)
  }

  add(id) {
    const item = this.items.get(id)
    if (!item) return
    this.cart.set(id, Math.min((this.cart.get(id) || 0) + 1, 99))
    this.announceTarget.textContent = `Added ${item.name}`
    this.clearResult()
    this.render()
  }

  step(id, delta) {
    const next = (this.cart.get(id) || 0) + delta
    if (next <= 0) this.cart.delete(id); else this.cart.set(id, Math.min(next, 99))
    this.render()
  }

  clear() { this.cart.clear(); this.idCheckedTarget.checked = false; this.cashTarget.value = ""; this.clearResult(); this.render() }

  lines() {
    return [...this.cart.entries()].map(([id, quantity]) => {
      const item = this.items.get(id)
      const lineCents = item.price_cents * quantity
      return { item, quantity, lineCents, taxCents: this.tax(lineCents) }
    })
  }

  // Half-up per line, like the server (Pos::EventSaleRecorder / PosEvent#tax_cents_for).
  tax(lineCents) { return Math.round((lineCents * this.stateValue.tax_rate_bps) / 10000) }

  totals() {
    const lines = this.lines()
    const subtotal = lines.reduce((sum, line) => sum + line.lineCents, 0)
    const tax = lines.reduce((sum, line) => sum + line.taxCents, 0)
    return { lines, subtotal, tax, total: subtotal + tax }
  }

  render() {
    const { lines, subtotal, tax, total } = this.totals()
    this.linesTarget.replaceChildren(...lines.map(line => {
      const row = this.el("div", "pos-line event-line")
      const text = this.el("div", "min-w-0")
      text.append(this.el("p", "pos-line-name", line.item.name), this.el("p", "pos-line-detail", `${this.money(line.item.price_cents)} each${line.item.card_eligible ? "" : " · cash only"}`))
      const controls = this.el("div", "pos-line-controls")
      const stepper = this.el("div", "pos-stepper pos-stepper-sm"); stepper.setAttribute("role", "group"); stepper.setAttribute("aria-label", `Quantity for ${line.item.name}`)
      const minus = this.el("button", "pos-step", "−"); minus.type = "button"; minus.setAttribute("aria-label", `One fewer ${line.item.name}`); minus.addEventListener("click", () => this.step(line.item.id, -1))
      const qty = this.el("span", "pos-step-value", String(line.quantity))
      const plus = this.el("button", "pos-step", "+"); plus.type = "button"; plus.setAttribute("aria-label", `One more ${line.item.name}`); plus.addEventListener("click", () => this.step(line.item.id, 1))
      stepper.append(minus, qty, plus); controls.append(stepper); text.append(controls)
      row.append(text, this.el("p", "pos-line-total retail-money", this.money(line.lineCents)))
      return row
    }))
    this.countTarget.textContent = String(lines.reduce((sum, line) => sum + line.quantity, 0))
    this.subtotalTarget.textContent = this.money(subtotal)
    this.taxTarget.textContent = this.money(tax)
    this.totalTarget.textContent = this.money(total)
    this.renderTender()
  }

  // --- tender ---

  choose(event) { this.tender = event.currentTarget.dataset.tender; this.renderCompliance(null); this.renderTender() }

  cashOnlyItems() { return this.lines().filter(line => !line.item.card_eligible).map(line => line.item.name) }

  renderTender() {
    this.tenderTargets.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.tender === this.tender)))
    const cash = this.tender === "cash"
    this.cashFieldsTarget.hidden = !cash
    const cashOnly = this.cashOnlyItems()
    const blockedCard = !cash && cashOnly.length > 0
    this.cardNoteTarget.hidden = cash
    this.cardNoteTarget.textContent = blockedCard
      ? `${cashOnly.join(", ")} ${cashOnly.length === 1 ? "is" : "are"} cash only. Take cash, or a manager can override while online.`
      : "Run the total on the event card terminal first. Record it here only after the terminal approves."
    if (blockedCard && this.online) this.showOverride(true)
    else if (!this.overrideOffered) this.showOverride(false)
    this.submitTarget.textContent = cash ? "Complete cash sale" : "Record card sale"
    this.submitTarget.disabled = this.cart.size === 0 || this.sending || (blockedCard && !this.online)
  }

  exact() { this.cashTarget.value = (this.totals().total / 100).toFixed(2) }
  quick(event) { this.cashTarget.value = Number(event.currentTarget.dataset.amount).toFixed(2) }

  showOverride(show) {
    this.overrideTarget.hidden = !show
    this.overrideTarget.disabled = !show
  }

  renderCompliance(compliance) {
    const blocking = (compliance?.issues || []).filter(issue => issue.severity === "block")
    this.issuesTarget.replaceChildren(...blocking.map(issue => { const li = this.el("li", "", issue.message); li.dataset.code = issue.code; return li }))
    this.issuesTarget.hidden = blocking.length === 0
    this.overrideOffered = Boolean(compliance?.overridable) && this.online
    this.showOverride(this.overrideOffered || (this.tender !== "cash" && this.cashOnlyItems().length > 0 && this.online))
  }

  // --- sale ---

  async submit(event) {
    event.preventDefault()
    if (this.sending || this.cart.size === 0) return
    const { total } = this.totals()
    if (!this.idCheckedTarget.checked) { this.statusTarget.textContent = "Check the customer’s ID (21 or older) and tick ID checked."; this.idCheckedTarget.focus(); return }
    let received = null
    if (this.tender === "cash") {
      received = this.cashTarget.value.trim()
      if (!/^\d{1,6}(\.\d{1,2})?$/.test(received) || Math.round(Number(received) * 100) < total) { this.statusTarget.textContent = "Enter the cash received, at least the total."; this.cashTarget.focus(); return }
    }
    const sale = {
      client_sale_id: crypto.randomUUID(), tender: this.tender, id_checked: true, cash_received: received,
      occurred_at: new Date().toISOString(), lines: this.lines().map(line => ({ event_item_id: line.item.id, quantity: line.quantity }))
    }
    if (!this.overrideTarget.disabled) Object.assign(sale, { override_user_id: this.overrideUserTarget.value, override_pin: this.overridePinTarget.value, override_reason: this.overrideReasonTarget.value })
    const usesOverride = Boolean(sale.override_pin)
    this.sending = true; this.renderTender(); this.statusTarget.textContent = "Recording sale…"
    try {
      const response = await this.post(sale)
      const result = await response.json()
      this.overridePinTarget.value = ""
      if (!response.ok) { this.renderCompliance(result.compliance); this.statusTarget.textContent = result.error || "The sale was not recorded."; return }
      this.done(result, false)
    } catch (_networkError) {
      this.overridePinTarget.value = ""
      if (usesOverride || (this.tender !== "cash" && this.cashOnlyItems().length > 0)) { this.statusTarget.textContent = "No connection. An override needs a connection: take cash or try again."; return }
      // Offline: keep it on this device without the override fields; send when online.
      this.enqueue({ ...sale, offline: true, override_user_id: undefined, override_pin: undefined, override_reason: undefined })
      this.setOnline(false)
      this.done({ total_cents: total, change_cents: received == null ? null : Math.round(Number(received) * 100) - total, tender: sale.tender }, true)
    } finally { this.sending = false; this.renderTender() }
  }

  done(result, queued) {
    this.cart.clear(); this.idCheckedTarget.checked = false; this.cashTarget.value = ""; this.overrideReasonTarget.value = ""; this.announceTarget.textContent = ""
    this.renderCompliance(null); this.render()
    this.statusTarget.textContent = queued ? `Saved on this device · ${this.money(result.total_cents)}. It sends when the connection returns.` : `Recorded · ${this.money(result.total_cents)}`
    this.resultTarget.replaceChildren()
    if (result.tender === "cash" && result.change_cents != null) this.resultTarget.append(this.el("p", "pos-change retail-money", `Change due ${this.money(result.change_cents)}`))
    if (result.receipt_url) {
      const link = this.el("a", "btn-ghost btn-lg", "Print receipt"); link.href = result.receipt_url; link.target = "_blank"; link.rel = "noopener"
      this.resultTarget.append(link)
    }
  }

  clearResult() { this.resultTarget.replaceChildren(); this.statusTarget.textContent = "" }

  post(sale) {
    return fetch(this.salesUrlValue, { method: "POST", headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" }, body: JSON.stringify(sale) })
  }

  // --- offline queue ---

  readQueue(suffix = "queue") { try { return JSON.parse(localStorage.getItem(`${this.queueKeyValue}:${suffix}`) || "[]") } catch { return [] } }
  writeQueue(list, suffix = "queue") { try { localStorage.setItem(`${this.queueKeyValue}:${suffix}`, JSON.stringify(list)) } catch { /* storage full or blocked */ } }

  enqueue(sale) {
    const queue = this.readQueue()
    if (queue.length >= QUEUE_LIMIT) { this.statusTarget.textContent = "This device holds too many unsent sales. Reconnect before selling more."; return }
    queue.push(sale); this.writeQueue(queue); this.renderQueue()
  }

  async sync() {
    if (this.syncing) return
    const queue = this.readQueue()
    if (queue.length === 0) { this.renderQueue(); return }
    this.syncing = true
    try {
      while (true) {
        const [sale] = this.readQueue()
        if (!sale) break
        let response
        try { response = await this.post(sale) } catch { this.setOnline(false); break }
        this.setOnline(true)
        if (response.ok) { this.writeQueue(this.readQueue().filter(s => s.client_sale_id !== sale.client_sale_id)); continue }
        if (response.status === 422) {
          const result = await response.json().catch(() => ({}))
          this.writeQueue([...this.readQueue("refused"), { ...sale, error: result.error || "Refused" }], "refused")
          this.writeQueue(this.readQueue().filter(s => s.client_sale_id !== sale.client_sale_id))
          continue
        }
        break // session expired or server error: keep the queue and try later
      }
    } finally { this.syncing = false; this.renderQueue() }
  }

  renderQueue() {
    const queued = this.readQueue().length
    this.queueBadgeTarget.hidden = queued === 0
    this.queueBadgeTarget.textContent = `${queued} unsent ${queued === 1 ? "sale" : "sales"}`
    const refused = this.readQueue("refused")
    this.refusedBoxTarget.hidden = refused.length === 0
    this.refusedListTarget.replaceChildren(...refused.map(sale => this.el("li", "", `${new Date(sale.occurred_at).toLocaleTimeString()} · ${sale.error}`)))
    if (this.online && queued === 0) this.connectionTarget.textContent = "Online · all sales sent"
  }

  setOnline(online) {
    this.online = online
    this.connectionTarget.className = online ? "pill-fern" : "pill-clay"
    this.connectionTarget.textContent = online ? "Online" : "Offline · saving sales on this device"
    this.renderTender()
    this.renderQueue()
  }

  // Picks up items pulled by a manager mid-event.
  async refresh() {
    try {
      const response = await fetch(this.stateUrlValue, { headers: { Accept: "application/json" } })
      if (!response.ok) return
      const state = await response.json()
      this.setOnline(true)
      if (state.status !== "open") { this.statusTarget.textContent = "This event was closed. Send any unsent sales to a manager."; this.submitTarget.disabled = true; return }
      const next = new Map(state.items.map(item => [item.id, item]))
      for (const id of [...this.cart.keys()]) if (!next.has(id)) this.cart.delete(id)
      this.items = next
      this.renderGrid(); this.render()
    } catch { this.setOnline(false) }
  }

  el(tag, className, text) { const node = document.createElement(tag); if (className) node.className = className; if (text != null) node.textContent = text; return node }
  money(cents) { return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(cents / 100) }
}
