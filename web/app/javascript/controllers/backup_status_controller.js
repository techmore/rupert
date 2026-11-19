import { Controller } from "@hotwired/stimulus"

// Settings → Backups. The recovery kit arrives as a file download, which leaves the page where it was, and the
// first backup lands a few minutes after the key is confirmed. This asks the server for the page's state every few
// seconds while something is expected to change and reloads once it has, so the owner never has to refresh by hand.
export default class extends Controller {
  static targets = ["hint"]
  static values = {
    url: String,
    signature: String,
    poll: Boolean,
    interval: { type: Number, default: 4000 },
    limit: { type: Number, default: 900000 }
  }

  connect() {
    if (this.pollValue) this.start()
  }

  disconnect() {
    this.stop()
  }

  // The "Turn on backups" form was submitted: the kit downloads and the page must move on to the check code.
  watch() {
    if (this.hasHintTarget) this.hintTarget.hidden = false
    this.start()
  }

  start() {
    if (this.timer) return
    this.startedAt = Date.now()
    this.timer = setInterval(() => this.check(), this.intervalValue)
  }

  stop() {
    clearInterval(this.timer)
    this.timer = null
  }

  async check() {
    if (Date.now() - this.startedAt > this.limitValue) return this.stop()
    if (document.hidden || this.inFlight) return
    this.inFlight = true
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!response.ok) return
      const data = await response.json()
      if (data.signature && data.signature !== this.signatureValue) {
        this.stop()
        window.location.assign(window.location.pathname)
      }
    } catch (_error) {
      // Offline or signed out: the next tick tries again; the owner can always refresh.
    } finally {
      this.inFlight = false
    }
  }
}
