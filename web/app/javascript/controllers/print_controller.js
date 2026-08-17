import { Controller } from "@hotwired/stimulus"

// Wraps the print buttons so the inline onclick="window.print()" handlers
// live inside the Stimulus setup.
export default class extends Controller {
  print() {
    window.print()
  }
}
