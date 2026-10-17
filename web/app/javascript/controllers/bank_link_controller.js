import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["status", "button"]
  static values = { resume: Boolean, tokenUrl: String, resumeUrl: String, exchangeUrl: String }

  connect() {
    this.closed = false
    if (this.resumeValue) this.open()
  }

  disconnect() {
    this.closed = true
    this.handler?.destroy()
  }

  async request(url, body = {}) {
    const response = await fetch(url, {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content },
      body: JSON.stringify(body)
    })
    if (!response.ok) {
      const result = await response.json().catch(() => ({}))
      throw new Error(result.error || "Bank connection unavailable. Reload, check setup and try again.")
    }
    return response.json()
  }

  async loadSdk() {
    if (window.Plaid) return
    await new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = "https://cdn.plaid.com/link/v2/stable/link-initialize.js"
      script.onload = resolve
      script.onerror = () => { script.remove(); reject(new Error("Could not load bank sign-in. Try again.")) }
      document.head.appendChild(script)
    })
  }

  async open() {
    if (this.busy) return
    this.busy = true
    this.buttonTargets.forEach(button => { button.disabled = true })
    this.statusTarget.textContent = "Opening secure bank sign-in…"
    try {
      const { link_token: token } = await this.request(this.resumeValue ? this.resumeUrlValue : this.tokenUrlValue)
      await this.loadSdk()
      if (this.closed) return
      this.handler?.destroy()
      this.handler = window.Plaid.create({
        token,
        ...(this.resumeValue ? { receivedRedirectUri: window.location.href } : {}),
        onSuccess: async (publicToken) => {
          if (this.closed) return
          this.statusTarget.textContent = "Saving bank consent…"
          try {
            const result = await this.request(this.exchangeUrlValue, { public_token: publicToken })
            if (!this.closed) window.location.assign(result.redirect_url)
          } catch (error) { this.showError(error) }
        },
        onExit: () => {
          if (this.closed) return
          this.statusTarget.textContent = "Bank sign-in closed. You can try again."
          this.reset()
        }
      })
      this.handler.open()
    } catch (error) { if (!this.closed) this.showError(error) }
  }

  reset() {
    this.busy = false
    this.resumeValue = false
    this.buttonTargets.forEach(button => { button.disabled = false })
    // Remove OAuth state from the address bar after consuming or abandoning it.
    const url = new URL(window.location.href)
    if (url.searchParams.has("oauth_state_id")) {
      url.searchParams.delete("oauth_state_id")
      window.history.replaceState({}, "", url)
    }
  }

  showError(error) {
    this.statusTarget.textContent = error.message
    this.reset()
  }
}
