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
    if (this.hasEnvResultTarget) this.envResultTarget.textContent = "Checking…"
    const form = new FormData(this.envFormTarget)
    // Preview first: show what would change, then apply on confirmation.
    fetch("/settings/env_preview", {
      method: "POST",
      body: form,
      headers: { "X-Requested-With": "XMLHttpRequest" },
    })
      .then((r) => r.json().then((b) => ({ ok: r.ok, body: b })))
      .then((res) => {
        if (!this.hasEnvResultTarget) return
        if (!res.ok) {
          this.envResultTarget.textContent = "Error: " + (res.body.error || "could not read that .env")
          return
        }
        const unknownNote = res.body.unknown.length ? " (" + res.body.unknown.length + " unrecognised key(s) skipped)" : ""
        const summary =
          res.body.added + " new key(s), " + res.body.updated + " update(s) to apply." + unknownNote +
          (res.body.keys.length === 0 ? " Nothing recognisable in this input." : "")
        if (res.body.keys.length === 0) {
          this.envResultTarget.textContent = summary
          return
        }
        if (!window.confirm(summary + "\n\nApply these changes now?")) {
          this.envResultTarget.textContent = "Import cancelled — nothing was changed."
          return
        }
        this.envResultTarget.textContent = "Importing…"
        fetch("/settings/env_import", {
          method: "POST",
          body: form,
          headers: { "X-Requested-With": "XMLHttpRequest" },
        })
          .then((r) => r.json().then((b) => ({ ok: r.ok, body: b })))
          .then((res2) => {
            if (!this.hasEnvResultTarget) return
            if (res2.ok) {
              this.envResultTarget.textContent = "Imported " + res2.body.imported.length + " key(s)."
              setTimeout(() => { window.location.reload() }, 800)
            } else {
              this.envResultTarget.textContent = "Error: " + (res2.body.error || "could not import")
            }
          })
          .catch(() => { if (this.hasEnvResultTarget) this.envResultTarget.textContent = "Error: import failed" })
      })
      .catch(() => { if (this.hasEnvResultTarget) this.envResultTarget.textContent = "Error: could not read that .env" })
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
