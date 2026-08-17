import { Controller } from "@hotwired/stimulus"

// Filters that submit their enclosing form on change (status selects).
// Replaces the old inline onchange="this.form.submit()" handlers.
export default class extends Controller {
  submit() {
    this.element.closest("form")?.requestSubmit()
  }
}
