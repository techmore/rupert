import { Controller } from "@hotwired/stimulus"

// Dashboard widget customizer: show/hide widgets, reorder them, and save the
// layout back to /dashboard/customize as JSON. Replaces the legacy inline
// <script> that did the same with raw DOM id lookups.
export default class extends Controller {
  static targets = ["toggle", "panel", "list", "status", "save", "reset", "done"]

  connect() {
    this.panelTarget.classList.add("hidden")
  }

  toggleEditor() {
    this.setCustomizing(!this.panelTarget.classList.contains("hidden"))
  }

  setCustomizing(on) {
    this.panelTarget.classList.toggle("hidden", !on)
    this.toggleTarget.textContent = on ? "Hide editor" : "Customize"
  }

  setCustomizingValue(value) {
    this.setCustomizing(value === "true" || value === true)
  }

  // Delegated handlers (listeners bound once in connect — works with dynamic
  // reordering because each element keeps its data-move / data-visible attrs).

  onMouseDown(e) {
    const btn = e.target.closest("[data-move]")
    if (btn) {
      e.preventDefault() // don't move focus to the button
      this.moveRow(btn.dataset.move, btn.dataset.dir)
      return
    }
    const cb = e.target.closest("[data-visible]")
    if (cb) {
      // Let the checkbox toggle normally, then sync the preview section.
      this.sectionFor(cb.dataset.visible).hidden = !cb.checked
    }
  }

  moveRow(key, dir) {
    const row = this.listTarget.querySelector(`[data-editor-key="${key}"]`)
    if (!row) return
    const section = this.sectionFor(key)
    const sibling = dir === "up" ? row.previousElementSibling : row.nextElementSibling
    if (!sibling) return
    this.listTarget.insertBefore(row, dir === "up" ? sibling : sibling.nextSibling)
    if (section) {
      const secSibling = dir === "up" ? section.previousElementSibling : section.nextElementSibling
      if (secSibling) section.parentNode.insertBefore(section, dir === "up" ? secSibling : secSibling.nextSibling)
    }
  }

  sectionFor(key) {
    return document.querySelector(`[data-widget-key="${key}"]`)
  }

  widgetConfig() {
    const order = Array.from(this.listTarget.querySelectorAll("[data-editor-key]")).map((li) => li.dataset.editorKey)
    const hidden = Array.from(this.listTarget.querySelectorAll("[data-visible]"))
      .filter((cb) => !cb.checked)
      .map((cb) => cb.dataset.visible)
    return { widgets: order, hidden: hidden }
  }

  save() {
    this.saveLayout(this.widgetConfig())
  }

  reset() {
    this.saveLayout({ reset: true })
  }

  saveLayout(body) {
    this.statusTarget.textContent = "Saving…"
    fetch("/dashboard/customize", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest" },
      body: JSON.stringify(body),
    })
      .then((r) => r.json().then((b) => ({ ok: r.ok, body: b })))
      .then((res) => {
        if (res.ok) window.location.reload()
        else this.statusTarget.textContent = "Error: " + (res.body.error || "could not save")
      })
      .catch(() => { this.statusTarget.textContent = "Error: could not save" })
  }
}
