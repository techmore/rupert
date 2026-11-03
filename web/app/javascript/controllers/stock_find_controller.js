import { Controller } from "@hotwired/stimulus"

// Rupert stock search, built for a keyboard-wedge scanner: the last code stays
// selected so the next scan replaces it instead of being appended, and the
// iPhone app's camera scanner (rupert:scanned) fills and submits the box.
export default class extends Controller {
  static targets = ["input", "camera"]

  connect() {
    this.scanned = (event) => this.useCode(event.detail)
    window.addEventListener("rupert:scanned", this.scanned)
    if (this.hasCameraTarget && this.nativeScanner) this.cameraTarget.hidden = false
    if (this.inputTarget.value && document.activeElement === this.inputTarget) this.inputTarget.select()
  }

  disconnect() {
    window.removeEventListener("rupert:scanned", this.scanned)
  }

  get nativeScanner() {
    return window.webkit?.messageHandlers?.rupertScanner
  }

  // Focusing a field that already holds a code selects it, ready for the next scan.
  selectAll() {
    this.inputTarget.select()
  }

  scanWithCamera(event) {
    event.preventDefault()
    this.nativeScanner?.postMessage({ action: "scan" })
  }

  useCode(code) {
    if (!code) return
    this.inputTarget.value = String(code).trim()
    this.element.requestSubmit()
  }
}
