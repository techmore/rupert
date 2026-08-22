import { Controller } from "@hotwired/stimulus"

// Dropdown menu with full keyboard support: Enter/Space toggles, ArrowDown/
// ArrowUp (or Home/End) move focus between menu items while open, Escape
// closes and returns focus to the trigger.
export default class extends Controller {
  static targets = ["menu", "trigger"]

  connect() {
    this.onKeydown = (e) => {
      if (e.key === "Escape") {
        if (this.isOpen) {
          e.stopPropagation()
          this.close()
          this.focusTrigger()
        }
        return
      }
      if (!this.isOpen) return
      const items = this.menuItems()
      if (!items.length) return
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        const current = items.indexOf(document.activeElement)
        let next
        if (current === -1) {
          next = e.key === "ArrowDown" ? 0 : items.length - 1
        } else {
          next = (current + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length
        }
        items[next].focus()
      } else if (e.key === "Home") {
        e.preventDefault()
        items[0].focus()
      } else if (e.key === "End") {
        e.preventDefault()
        items[items.length - 1].focus()
      }
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
    // Move focus into the menu so keyboard users land inside it.
    const first = this.menuItems()[0]
    if (first) first.focus()
  }

  close() {
    this.menuTarget.classList.add("hidden")
    this.setExpanded(false)
  }

  menuItems() {
    return Array.from(
      this.menuTarget.querySelectorAll('a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])')
    )
  }

  focusTrigger() {
    if (this.hasTriggerTarget) this.triggerTarget.focus()
  }

  setExpanded(value) {
    if (this.hasTriggerTarget) this.triggerTarget.setAttribute("aria-expanded", String(value))
    else this.element.setAttribute("aria-expanded", String(value))
  }

  get isOpen() {
    return !this.menuTarget.classList.contains("hidden")
  }
}
