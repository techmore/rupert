import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu"]

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
    this.element.setAttribute("aria-expanded", "true")
  }

  close() {
    this.menuTarget.classList.add("hidden")
    this.element.setAttribute("aria-expanded", "false")
  }

  get isOpen() {
    return !this.menuTarget.classList.contains("hidden")
  }
}
