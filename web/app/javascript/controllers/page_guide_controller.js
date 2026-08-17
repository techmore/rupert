import { Controller } from "@hotwired/stimulus"

// Collapsible "How this page works" guide panel (the PageGuides content was
// rendered but never visible — the icon had no interaction).
export default class extends Controller {
  static targets = ["panel", "trigger"]

  connect() {
    this.panelTarget.classList.add("hidden")
  }

  toggle() {
    const open = this.panelTarget.classList.toggle("hidden") === false
    this.triggerTarget.setAttribute("aria-expanded", String(open))
  }
}
