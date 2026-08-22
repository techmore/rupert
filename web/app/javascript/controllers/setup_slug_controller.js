import { Controller } from "@hotwired/stimulus"

// Pre-fills the subdomain from the business name so first-run users don't
// have to invent a slug. Stops syncing once the user edits the field by hand.
export default class extends Controller {
  static targets = ["name", "slug"]

  connect() {
    this.userEdited = this.slugTarget.value.length > 0
  }

  sync() {
    if (this.userEdited) return
    const slug = (this.nameTarget.value || "")
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[\u0300-\u036f]/g, "") // strip accents
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
    this.slugTarget.value = slug
  }

  // Mark as user-edited only when the user actually types in the slug field.
  onSlugInput() {
    this.userEdited = true
  }
}
