import { Controller } from "@hotwired/stimulus"

// Time-off request form: picking a first day moves the last day along with it when the last day
// would fall before it, so a one-day request is one tap.
export default class extends Controller {
  static values = { defaultUrl: String }

  syncEnd(event) {
    const start = event.target.value
    const end = this.element.querySelector('input[name="leave_request[ends_on]"]')
    if (!end) return
    if (!end.value || end.value < start) end.value = start
    end.min = start
  }
}
