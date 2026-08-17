import { Controller } from "@hotwired/stimulus"

// Inventory count sheet: add rows from an HTML <template>, remove rows, and
// make Enter advance from one count input to the next.
export default class extends Controller {
  static targets = ["rows", "template"]

  addRow() {
    const row = this.templateTarget.content.firstElementChild.cloneNode(true)
    this.rowsTarget.appendChild(row)
    row.querySelector("input")?.focus()
  }

  removeRow(e) {
    if (!e.target.matches("[data-remove-row]")) return
    const row = e.target.closest("[data-row]")
    if (!row) return
    if (this.rowsTarget.children.length > 1) {
      row.remove()
    } else {
      row.querySelector("input[type=text]").value = ""
      row.querySelector("input[type=number]").value = ""
    }
  }

  // Enter advances to the next count input (or blurs on the last).
  advanceOnEnter(e) {
    if (e.key !== "Enter") return
    const inputs = Array.from(document.querySelectorAll("[data-count-input]"))
    const idx = inputs.indexOf(e.target)
    if (idx === -1) return
    e.preventDefault()
    const next = inputs[idx + 1]
    if (next) next.focus()
    else e.target.blur()
  }
}
