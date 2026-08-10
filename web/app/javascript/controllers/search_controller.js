import { Controller } from "@hotwired/stimulus"

// Global search command palette. "/" focuses it, Escape closes, arrow keys
// move through results, Enter opens the selected row. Results are fetched from
// /search?q= and rendered as Turbo navigation links.
export default class extends Controller {
  static targets = ["input", "results", "empty"]

  connect() {
    this.selected = -1
    this.rows = []
    this.onKeydown = (e) => this.globalKeydown(e)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  globalKeydown(e) {
    if (e.key === "/" && !this.isTypingInField(e.target)) {
      e.preventDefault()
      this.open()
    } else if (e.key === "Escape" && this.element.classList.contains("open")) {
      this.close()
    }
  }

  isTypingInField(el) {
    return el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT" || el.isContentEditable)
  }

  open() {
    this.element.classList.remove("hidden")
    this.element.classList.add("open")
    this.inputTarget.focus()
    this.inputTarget.select()
    if (this.inputTarget.value.trim().length >= 2) this.search()
  }

  close() {
    this.element.classList.add("hidden")
    this.element.classList.remove("open")
    this.selected = -1
  }

  search() {
    const q = this.inputTarget.value.trim()
    if (q.length < 2) {
      this.rows = []
      this.render([])
      return
    }
    fetch(`/search?q=${encodeURIComponent(q)}`, {
      headers: { "Accept": "application/json", "X-Requested-With": "XMLHttpRequest" }
    })
      .then(r => (r.ok ? r.json() : []))
      .then(results => this.render(results))
      .catch(() => this.render([]))
  }

  render(results) {
    this.rows = results
    this.selected = -1
    this.resultsTarget.innerHTML = ""

    if (!results.length) {
      this.resultsTarget.classList.add("hidden")
      if (this.emptyTarget) this.emptyTarget.classList.remove("hidden")
      return
    }

    this.resultsTarget.classList.remove("hidden")
    if (this.emptyTarget) this.emptyTarget.classList.add("hidden")

    results.forEach((r, i) => {
      const a = document.createElement("a")
      a.href = r.path
      a.dataset.index = String(i)
      a.className = "flex items-center justify-between gap-3 px-4 py-2.5 text-sm hover:bg-haze"
      const left = document.createElement("span")
      left.className = "min-w-0"
      const label = document.createElement("span")
      label.className = "block truncate font-medium text-ink"
      label.textContent = r.label
      const sub = document.createElement("span")
      sub.className = "block truncate text-xs text-taupe"
      sub.textContent = r.sub_label || ""
      left.append(label, sub)
      const type = document.createElement("span")
      type.className = "shrink-0 rounded-full bg-haze px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-taupe"
      type.textContent = r.type
      a.append(left, type)
      a.addEventListener("mouseenter", () => this.select(i))
      this.resultsTarget.appendChild(a)
    })
  }

  keydown(e) {
    if (e.key === "ArrowDown") {
      e.preventDefault()
      this.move(1)
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this.move(-1)
    } else if (e.key === "Enter") {
      e.preventDefault()
      this.activate()
    }
  }

  move(dir) {
    if (!this.rows.length) return
    this.selected = (this.selected + dir + this.rows.length) % this.rows.length
    this.highlight()
  }

  activate() {
    const row = this.rows[this.selected] || this.rows[0]
    if (row) window.location.href = row.path
  }

  select(i) {
    this.selected = i
    this.highlight()
  }

  highlight() {
    this.resultsTarget.querySelectorAll("a").forEach(a => {
      const on = String(this.selected) === a.dataset.index
      a.classList.toggle("bg-haze", on)
      a.classList.toggle("text-olive", on)
    })
  }
}
