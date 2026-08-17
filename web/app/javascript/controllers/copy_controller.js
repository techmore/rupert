import { Controller } from "@hotwired/stimulus"

// Copies text to the clipboard with a brief "Copied!" confirmation. The text
// comes from a data-copy-target source element's text content, or from a
// data-copy-text value on the controller element. Replaces the old inline
// navigator.clipboard onclick handlers.
export default class extends Controller {
  static targets = ["source", "status"]

  copy() {
    const text = this.hasSourceTarget
      ? this.sourceTarget.textContent.trim()
      : (this.element.dataset.copyText || "")
    if (!text) return

    const done = () => {
      if (this.hasStatusTarget) {
        this.statusTarget.hidden = false
        setTimeout(() => { this.statusTarget.hidden = true }, 2000)
      }
    }
    if (navigator.clipboard) {
      navigator.clipboard.writeText(text).then(done).catch(done)
    } else {
      this.fallbackCopy(text)
      done()
    }
  }

  fallbackCopy(text) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()
    document.execCommand("copy")
    document.body.removeChild(textarea)
  }
}
