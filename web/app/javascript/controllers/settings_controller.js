import { Controller } from "@hotwired/stimulus"

// Settings page: renders the environment key list, handles .env import and
// database restore. Replaces the corresponding inline <script> logic.
export default class extends Controller {
  static targets = ["envList", "envForm", "envResult", "restoreFile", "restoreResult"]

  connect() {
    this.loadEnv()
  }

  loadEnv() {
    fetch("/settings/env.json", { headers: { "X-Requested-With": "XMLHttpRequest" } })
      .then((r) => r.json())
      .then((data) => {
        if (!this.hasEnvListTarget) return
        this.envListTarget.innerHTML = ""
        data.keys.forEach((item) => {
          const row = document.createElement("div")
          row.className = "flex items-center justify-between gap-4 rounded-xl bg-haze px-4 py-2.5 text-sm"
          const key = item.key.replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" }[c]))
          const sub = (item.source + (item.set ? " · " + item.masked : " · not set")).replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" }[c]))
          row.innerHTML =
            '<div><p class="font-mono text-xs text-ink">' + key + "</p>" +
            '<p class="text-[11px] text-taupe">' + sub + "</p></div>" +
            '<span class="' + (item.set ? "dot bg-fern" : "dot bg-taupe") + '"></span>'
          this.envListTarget.appendChild(row)
        })
      })
  }

  submitEnv(e) {
    e.preventDefault()
    if (this.hasEnvResultTarget) this.envResultTarget.textContent = "Importing…"
    const form = new FormData(this.envFormTarget)
    fetch("/settings/env_import", {
      method: "POST",
      body: form,
      headers: { "X-Requested-With": "XMLHttpRequest" },
    })
      .then((r) => r.json().then((b) => ({ ok: r.ok, body: b })))
      .then((res) => {
        if (!this.hasEnvResultTarget) return
        if (res.ok) {
          this.envResultTarget.textContent = "Imported " + res.body.imported.length + " key(s)."
          setTimeout(() => { window.location.reload() }, 800)
        } else {
          this.envResultTarget.textContent = "Error: " + (res.body.error || "could not import")
        }
      })
      .catch(() => { if (this.hasEnvResultTarget) this.envResultTarget.textContent = "Error: import failed" })
  }

  restore(e) {
    const file = e.target.files[0]
    if (!file) return
    if (!window.confirm("Restore this backup? This replaces ALL current data in the database. This cannot be undone.")) {
      e.target.value = ""
      return
    }
    if (this.hasRestoreResultTarget) this.restoreResultTarget.textContent = "Restoring…"
    const form = new FormData()
    form.append("file", file)
    const url = e.target.dataset.url
    fetch(url, {
      method: "POST",
      body: form,
      headers: { "X-Requested-With": "XMLHttpRequest" },
    })
      .then((r) => r.json().then((b) => ({ ok: r.ok, body: b })))
      .then((res) => {
        if (!this.hasRestoreResultTarget) return
        this.restoreResultTarget.textContent = res.ok ? "Restored. Reloading…" : "Error: " + (res.body.error || "restore failed")
        if (res.ok) setTimeout(() => { window.location.reload() }, 1000)
      })
      .catch(() => { if (this.hasRestoreResultTarget) this.restoreResultTarget.textContent = "Error: restore failed" })
  }
}
