import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "trigger"]

  connect() {
    this.onKeydown = (e) => {
      if (e.key === "Escape") this.close()
    }
    this.onPointerdown = (e) => {
      if (!this.element.contains(e.target)) this.close()
    }
    document.addEventListener("keydown", this.onKeydown)
    document.addEventListener("pointerdown", this.onPointerdown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("pointerdown", this.onPointerdown)
  }

  toggle() {
    this.isOpen ? this.close() : this.open()
  }

  open() {
    this.menuTarget.classList.remove("hidden")
    this.setExpanded(true)
  }

  close() {
    this.menuTarget.classList.add("hidden")
    this.setExpanded(false)
  }

  setExpanded(value) {
    if (this.hasTriggerTarget) this.triggerTarget.setAttribute("aria-expanded", value.toLocaleString())
    else this.element.setAttribute("aria-expanded", value.toLocaleString())
  }

  get isOpen() {
    return !this.menuTarget.classList.contains("hidden")
  }
}
