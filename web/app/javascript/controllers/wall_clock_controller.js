import { Controller } from '@hotwired/stimulus'

// A live wall clock in the store's zone (the kiosk header). The server renders the first value;
// this keeps it moving. `zone` is an IANA name; without one the browser's zone is used.
export default class extends Controller {
  static values = { zone: String }

  connect() {
    this.render()
    this.timer = setInterval(() => this.render(), 10_000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  render() {
    try {
      this.element.textContent = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit', timeZone: this.zoneValue || undefined }).format(new Date())
    } catch {
      this.element.textContent = new Date().toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
    }
  }
}
