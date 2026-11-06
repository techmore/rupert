import { Controller } from "@hotwired/stimulus"

// Lesson editor helpers: add a blank question row from the template, and render
// a preview of the lesson text through the server (the same renderer learners get).
export default class extends Controller {
  static targets = ["body", "preview", "questions", "template"]
  static values = { previewUrl: String }

  addQuestion() {
    const html = this.templateTarget.innerHTML.replace(/NEW_INDEX/g, Date.now().toString())
    this.templateTarget.insertAdjacentHTML("beforebegin", html)
  }

  async preview() {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const body = new FormData()
    body.append("body", this.bodyTarget.value)
    const response = await fetch(this.previewUrlValue, { method: "POST", body, headers: { "X-CSRF-Token": token, Accept: "text/html" } })
    this.previewTarget.innerHTML = response.ok ? await response.text() : "<p class=\"text-sm text-rose\">Preview failed.</p>"
    this.previewTarget.hidden = false
  }
}
