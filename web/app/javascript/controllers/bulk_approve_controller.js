import { Controller } from "@hotwired/stimulus"

// Bulk approve bar on the timesheets list: "Select all clean" ticks only the clean rows, and the
// one primary button always says how many it will approve ("Approve 5"). Disabled at zero.
export default class extends Controller {
  static targets = ["button"]

  connect() { this.recount() }

  boxes() { return Array.from(this.element.closest("form").querySelectorAll(".bulk-box")) }

  toggleAll(event) {
    this.boxes().forEach((box) => { box.checked = event.target.checked })
    this.recount()
  }

  recount() {
    const count = this.boxes().filter((box) => box.checked).length
    if (!this.hasButtonTarget) return
    this.buttonTarget.value = count > 0 ? `Approve ${count}` : "Approve selected"
    this.buttonTarget.disabled = count === 0
  }
}
