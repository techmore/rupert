import { Controller } from "@hotwired/stimulus"

// Checkout step of the cashier cart. Sends only the display, tender, register and cash
// physically received; the server takes the amount from the frozen checkout. Cash, Card and
// Card (A920) are big buttons over one hidden tender field; an unavailable tender stays
// disabled. Card (A920) records a card already run on the A920 terminal: no gateway charge.
const A920 = "card_a920"
export default class extends Controller {
  static targets = ["tender", "tenderButton", "cashFields", "cash", "a920Fields", "exact", "submit", "status", "result", "idChecked", "issues", "override", "overrideUser", "overridePin", "overrideReason"]
  static values = { url: String, displayId: Number, demo: Boolean, terminal: Boolean }

  connect() {
    this.tenderChanged()
    this.stateListener = event => {
      this.totalCents = event.detail.totalCents ?? null
      if (this.hasExactTarget) this.exactTarget.disabled = this.totalCents == null
      this.renderCheckout(event.detail.checkout)
    }
    this.element.closest('[data-controller~="pos-display"]')?.addEventListener('pos-display:state', this.stateListener)
  }

  disconnect() { this.element.closest('[data-controller~="pos-display"]')?.removeEventListener('pos-display:state', this.stateListener) }

  choose(event) {
    if (event.currentTarget.disabled) return
    this.tenderTarget.value = event.currentTarget.dataset.tender
    this.tenderChanged()
    if (this.tenderTarget.value === "cash") this.cashTarget.focus()
    else this.submitTarget.focus()
  }

  tenderChanged() {
    const tender = this.tenderTarget.value
    const cash = tender === "cash"
    const available = this.tenderButtonTargets.find(button => button.dataset.tender === tender)?.dataset.available !== "false"
    this.tenderButtonTargets.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.tender === tender)))
    const a920 = tender === A920
    this.cashFieldsTarget.hidden = !cash
    this.cashTarget.required = cash
    if (this.hasA920FieldsTarget) this.a920FieldsTarget.hidden = !a920
    this.submitTarget.value = this.submitLabel(cash, a920)
    this.submitTarget.disabled = !available
  }

  submitLabel(cash, a920) {
    if (a920) return this.demoValue ? "Run demo A920 card sale" : "Record A920 card sale"
    if (!cash && this.terminalValue && !this.demoValue) return "Send card sale to terminal"
    return this.demoValue ? (cash ? "Run demo cash checkout" : "Send demo card checkout") : (cash ? "Complete cash sale" : "Send card checkout to customer screen")
  }

  // Quick cash: the customer-confirmed total (server cents) or a common bill.
  exact() {
    if (this.totalCents == null) return
    this.cashTarget.value = (this.totalCents / 100).toFixed(2)
    this.submitTarget.focus()
  }

  quick(event) {
    this.cashTarget.value = Number(event.currentTarget.dataset.amount).toFixed(2)
    this.submitTarget.focus()
  }

  async submit(event) {
    event.preventDefault()
    if (!event.target.reportValidity() || this.submitting) return
    this.submitting = true; this.submitTarget.disabled = true; this.statusTarget.textContent = "Checking source totals and payment…"
    const form = new FormData(event.target)
    try {
      const body = { display_id: this.displayIdValue, tender: form.get("tender"), register_id: form.get("register_id"), cash_received: form.get("cash_received"), ...this.complianceFields() }
      const response = await fetch(this.urlValue, { method: "POST", headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" }, body: JSON.stringify(body) })
      const result = await response.json()
      if (this.hasOverridePinTarget) this.overridePinTarget.value = ""
      if (!response.ok) { this.renderCompliance(result.compliance); throw new Error(result.error || "Checkout could not be verified. Check the receipt before retrying.") }
      this.renderCompliance(null)
      this.renderCheckout(result)
    } catch (error) { this.statusTarget.textContent = error.message }
    finally { this.submitting = false; this.tenderChanged() }
  }

  // Locked registers (F70): ID confirmation and, once the server offers it, a manager override.
  complianceFields() {
    if (!this.hasIdCheckedTarget) return {}
    const fields = { id_checked: this.idCheckedTarget.checked }
    if (this.hasOverrideTarget && !this.overrideTarget.disabled && this.hasOverridePinTarget) {
      Object.assign(fields, { override_user_id: this.overrideUserTarget.value, override_pin: this.overridePinTarget.value, override_reason: this.overrideReasonTarget.value })
    }
    return fields
  }

  renderCompliance(compliance) {
    if (!this.hasIssuesTarget) return
    const blocking = (compliance?.issues || []).filter(issue => issue.severity === "block")
    this.issuesTarget.replaceChildren(...blocking.map(issue => { const item = document.createElement("li"); item.textContent = issue.message; item.dataset.code = issue.code; return item }))
    this.issuesTarget.hidden = blocking.length === 0
    const overridable = Boolean(compliance?.overridable)
    if (this.hasOverrideTarget) { this.overrideTarget.hidden = !overridable; this.overrideTarget.disabled = !overridable }
  }

  renderCheckout(result) {
    if (!result) { if (this.lastReceipt) { this.resultTarget.replaceChildren(); this.statusTarget.textContent = ""; this.lastReceipt = null }; return }
    const signature = JSON.stringify(result)
    if (signature === this.lastReceipt) return
    this.lastReceipt = signature
    if (result.terminal && result.status !== "paid") { this.renderTerminal(result); return }
    this.statusTarget.textContent = result.status === "paid" ? `${result.sandbox ? "Sandbox completed" : (result.demo ? "Demo completed" : "Paid")} · ${this.money(result.total_cents)}${result.tender === A920 ? " · Card (A920), no gateway charge" : ""}${result.tender === "cash" ? ` · Change ${this.money(result.change_cents)}` : ""}${result.inventory_pending ? " · Stock update pending verification" : ""}` : ["processing", "unknown"].includes(result.status) ? "Payment is unresolved. Check the receipt/gateway; do not submit another charge." : "Customer can now pay privately on their screen."
    this.resultTarget.replaceChildren()
    if (result.status === "paid") {
      const text = document.createElement("p"); text.className = "pos-checkout-hint"; text.textContent = `Receipt ${result.reference}.`; this.resultTarget.append(text)
      if (result.tender === "cash" && result.change_cents != null) {
        const change = document.createElement("p"); change.className = "pos-change retail-money"; change.textContent = `Change due ${this.money(result.change_cents)}`; this.resultTarget.append(change)
      }
      const actions = document.createElement("div"); actions.className = "pos-checkout-actions"
      const next = document.createElement("button"); next.type = "button"; next.className = "btn-primary btn-lg"; next.textContent = "New sale"; next.dataset.action = "pos-cart#clear pos-screen#newSale"
      const link = document.createElement("a"); link.href = `${this.urlValue}/${result.id}`; link.textContent = "Open receipt"; link.target = "_blank"; link.rel = "noopener"; link.className = "btn-ghost btn-lg"
      actions.append(next, link); this.resultTarget.append(actions)
    }
    else if (["ready", "declined"].includes(result.status)) { const cancel = document.createElement("button"); cancel.type = "button"; cancel.className = "btn-ghost"; cancel.textContent = "Cancel unpaid checkout"; cancel.addEventListener("click", async () => { const response = await fetch(`${this.urlValue}/${result.id}/cancel`, { method: "POST", headers: { "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content } }); if (response.ok) window.location.reload(); else this.statusTarget.textContent = "Payment cannot be cancelled. Check the gateway status." }); this.resultTarget.append(cancel) }
  }

  // Dejavoo terminal: the customer pays on the terminal; the register sends,
  // waits (the display poll refreshes this) and can cancel. It never sends a
  // second sale while one is waiting or unknown.
  renderTerminal(result) {
    const waiting = result.status === "processing"
    this.statusTarget.textContent = waiting ? "Waiting for the customer to tap, insert or swipe on the terminal…"
      : result.status === "unknown" ? "The terminal did not confirm this payment. Do not charge again; open the receipt to check status."
      : result.status === "declined" ? (result.decline_reason || "Not paid. Nothing was charged.") : "Ready to send to the terminal."
    this.resultTarget.replaceChildren()
    const actions = document.createElement("div"); actions.className = "pos-checkout-actions"
    if (waiting) actions.append(this.button("Cancel on terminal", "btn-ghost btn-lg", `${result.id}/terminal_cancel`))
    else if (["ready", "declined"].includes(result.status)) {
      actions.append(this.button(result.status === "declined" ? "Send to terminal again" : "Send to terminal", "btn-primary btn-lg", `${result.id}/terminal`))
      actions.append(this.button("Cancel unpaid checkout", "btn-ghost", `${result.id}/cancel`, true))
    } else {
      const link = document.createElement("a"); link.href = `${this.urlValue}/${result.id}`; link.textContent = "Open receipt"; link.target = "_blank"; link.rel = "noopener"; link.className = "btn-ghost btn-lg"; actions.append(link)
    }
    this.resultTarget.append(actions)
  }

  button(label, className, path, reload = false) {
    const button = document.createElement("button"); button.type = "button"; button.className = className; button.textContent = label
    button.addEventListener("click", async () => {
      button.disabled = true
      try {
        const response = await fetch(`${this.urlValue}/${path}`, { method: "POST", headers: { Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" } })
        const result = await response.json().catch(() => ({}))
        if (!response.ok) throw new Error(result.error || "The terminal request could not be verified. Do not charge again; check the receipt.")
        if (reload) { window.location.reload(); return }
        this.lastReceipt = null; this.renderCheckout(result)
      } catch (error) { this.statusTarget.textContent = error.message; button.disabled = false }
    })
    return button
  }

  money(cents) { return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(cents / 100) }
}
