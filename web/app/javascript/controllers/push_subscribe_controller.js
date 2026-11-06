import { Controller } from "@hotwired/stimulus"

// Subscribes the installed staff web app to Web Push (VAPID) and posts the subscription to Rupert.
export default class extends Controller {
  static targets = ["status", "button"]
  static values = { key: String, url: String, worker: String }

  connect() {
    if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
      this.statusTarget.textContent = "This browser cannot receive push notifications. Install the app from Safari's Share menu on iPhone, or use Chrome."
      this.buttonTarget.hidden = true
    }
  }

  async subscribe() {
    this.buttonTarget.disabled = true
    try {
      const permission = await Notification.requestPermission()
      if (permission !== "granted") {
        this.statusTarget.textContent = "Notifications are blocked for this site. Allow them in your browser settings to turn push on."
        return
      }
      await navigator.serviceWorker.register(this.workerValue, { scope: "/" })
      const ready = await navigator.serviceWorker.ready
      const subscription = await ready.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: this.decodeKey(this.keyValue) })
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(this.urlValue, {
        method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": token, Accept: "application/json" },
        body: JSON.stringify({ subscription: subscription.toJSON() })
      })
      if (!response.ok) throw new Error(`Rupert answered ${response.status}`)
      this.statusTarget.textContent = "Push notifications are on for this device."
      this.buttonTarget.hidden = true
    } catch (error) {
      this.statusTarget.textContent = `Could not turn on push: ${error.message}`
      this.buttonTarget.disabled = false
    }
  }

  decodeKey(base64) {
    const padding = "=".repeat((4 - (base64.length % 4)) % 4)
    const raw = atob((base64 + padding).replace(/-/g, "+").replace(/_/g, "/"))
    return Uint8Array.from(raw, (c) => c.charCodeAt(0))
  }
}
