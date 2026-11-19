import { Controller } from "@hotwired/stimulus"

// Tap-to-define word inside lesson text. A <button> and a hidden panel (not <details>,
// which browsers refuse inside a paragraph). The open panel is pinned to the viewport like
// the shared term popover; Escape, an outside click or a scroll closes it.
export default class extends Controller {
  static targets = ["panel"]

  connect() {
    this.onKey = (event) => { if (event.key === "Escape") this.close() }
    this.onOutside = (event) => { if (!this.element.contains(event.target)) this.close() }
    this.onScroll = () => this.close()
  }

  disconnect() { this.close() }

  toggle() { this.panelTarget.hidden ? this.open() : this.close() }

  open() {
    const button = this.element.querySelector("button")
    const panel = this.panelTarget
    panel.hidden = false
    button.setAttribute("aria-expanded", "true")
    const rect = button.getBoundingClientRect()
    const width = Math.min(320, window.innerWidth - 32)
    const left = Math.max(16, Math.min(rect.left, window.innerWidth - width - 16))
    const height = panel.offsetHeight || 160
    const below = rect.bottom + 8 + height <= window.innerHeight || rect.top < height + 8
    Object.assign(panel.style, {
      position: "fixed", width: `${width}px`, left: `${left}px`, right: "auto",
      top: below ? `${rect.bottom + 8}px` : "auto",
      bottom: below ? "auto" : `${window.innerHeight - rect.top + 8}px`
    })
    document.addEventListener("keydown", this.onKey)
    document.addEventListener("click", this.onOutside, true)
    window.addEventListener("scroll", this.onScroll, true)
  }

  close() {
    if (!this.hasPanelTarget || this.panelTarget.hidden) return
    this.panelTarget.hidden = true
    this.element.querySelector("button")?.setAttribute("aria-expanded", "false")
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("click", this.onOutside, true)
    window.removeEventListener("scroll", this.onScroll, true)
  }
}
