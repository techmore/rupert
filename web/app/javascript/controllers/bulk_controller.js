import { Controller } from "@hotwired/stimulus"

// Reusable bulk-selection for list tables: a "select all" header checkbox
// toggles every row, a sticky-ish action bar shows a running count, and any
// submit carries the checked ids as `alert_ids[]`-style params (the field name
// is taken from the form's data-bulk-param, defaulting to a generic `ids[]`).
export default class extends Controller {
  static targets = ["all", "rows", "actions", "count"]

  connect() {
    this.sync()
  }

  toggleAll(e) {
    const checked = e.target.checked
    this.rowTargets.forEach(row => {
      const box = row.querySelector("input[type=checkbox][data-bulk-row]")
      if (box) box.checked = checked
    })
    this.sync()
  }

  toggleRow() {
    this.sync()
  }

  sync() {
    const boxes = this.rowTargets.map(r => r.querySelector("input[type=checkbox][data-bulk-row]")).filter(Boolean)
    const checked = boxes.filter(b => b.checked)
    const all = boxes.length > 0 && checked.length === boxes.length
    if (this.hasAllTarget) this.allTarget.checked = all
    this.toggleActions(checked.length)
  }

  toggleActions(n) {
    if (!this.hasActionsTarget) return
    this.actionsTarget.classList.toggle("hidden", n === 0)
    this.actionsTarget.classList.toggle("flex", n > 0)
    if (this.hasCountTarget) {
      this.countTarget.textContent = n === 0 ? "Select rows to update" : `${n} selected`
    }
  }
}
