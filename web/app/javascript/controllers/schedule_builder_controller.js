import { Controller } from "@hotwired/stimulus"

// The schedule builder grid (people × days). Drag a shift chip to another day or person, drag its
// lower edge to change the end time, click an empty cell to add. Every change is one JSON request
// to the shifts controller, which answers with the re-rendered chip, its warning chips and the
// labour line, so the grid never reloads while a manager is planning.
export default class extends Controller {
  static targets = ["grid", "dialog", "form", "dialogTitle", "error", "fieldId", "fieldDate", "fieldEmployee", "fieldStart", "fieldEnd",
    "fieldPosition", "fieldBreak", "fieldRole", "fieldLocation", "fieldNotes", "saveButton", "removeButton", "labor", "status"]
  static values = { createUrl: String, location: String, week: String, canWrite: Boolean }

  connect() {
    this.dragging = null
    this.resizing = null
    this.onPointerMove = (event) => this.resizeMove(event)
    this.onPointerUp = (event) => this.resizeEnd(event)
  }

  // ---- drag and drop -------------------------------------------------------------------

  dragStart(event) {
    const chip = event.currentTarget
    this.dragging = chip
    chip.classList.add("shift-chip-dragging")
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", chip.dataset.shiftId)
  }

  dragEnd(event) {
    event.currentTarget.classList.remove("shift-chip-dragging")
    this.dragging = null
    this.element.querySelectorAll(".schedule-grid-cell-over").forEach((cell) => cell.classList.remove("schedule-grid-cell-over"))
  }

  dragOver(event) {
    if (!this.dragging) return
    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    event.currentTarget.classList.add("schedule-grid-cell-over")
  }

  dragLeave(event) {
    event.currentTarget.classList.remove("schedule-grid-cell-over")
  }

  async drop(event) {
    event.preventDefault()
    const cell = event.currentTarget
    cell.classList.remove("schedule-grid-cell-over")
    const chip = this.dragging
    this.dragging = null
    if (!chip) return
    const sameCell = chip.dataset.employeeId === cell.dataset.employeeId && chip.dataset.date === cell.dataset.date
    if (sameCell) return
    const start = this.moveToDate(chip.dataset.startsAt, cell.dataset.date)
    const end = this.moveToDate(chip.dataset.endsAt, cell.dataset.date, chip.dataset.startsAt)
    const payload = { employee_id: cell.dataset.employeeId || "open", starts_at: start, ends_at: end }
    await this.save(chip.dataset.shiftId, payload, chip, cell)
  }

  // Keeps the wall-clock time, changes the calendar day. The end keeps its offset from the start.
  moveToDate(iso, date, startIso) {
    const source = new Date(iso)
    if (startIso) {
      const offset = source.getTime() - new Date(startIso).getTime()
      const movedStart = new Date(this.moveToDate(startIso, date))
      return new Date(movedStart.getTime() + offset).toISOString()
    }
    const [y, m, d] = date.split("-").map(Number)
    const moved = new Date(source)
    moved.setFullYear(y, m - 1, d)
    return moved.toISOString()
  }

  // ---- resize (drag the lower edge, 15-minute steps) -------------------------------------

  resizeStart(event) {
    event.preventDefault()
    event.stopPropagation()
    const chip = event.currentTarget.closest(".shift-chip")
    chip.draggable = false
    this.resizing = { chip, startY: event.clientY, endsAt: new Date(chip.dataset.endsAt), minutes: 0 }
    chip.classList.add("shift-chip-resizing")
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp, { once: true })
  }

  resizeMove(event) {
    if (!this.resizing) return
    const steps = Math.round((event.clientY - this.resizing.startY) / 12)
    this.resizing.minutes = steps * 15
    const preview = new Date(this.resizing.endsAt.getTime() + this.resizing.minutes * 60000)
    this.resizing.chip.querySelector(".shift-chip-time").textContent = `${this.clock(new Date(this.resizing.chip.dataset.startsAt))} – ${this.clock(preview)}`
  }

  async resizeEnd() {
    window.removeEventListener("pointermove", this.onPointerMove)
    const state = this.resizing
    this.resizing = null
    if (!state) return
    state.chip.classList.remove("shift-chip-resizing")
    state.chip.draggable = true
    if (state.minutes === 0) {
      state.chip.querySelector(".shift-chip-time").textContent = `${this.clock(new Date(state.chip.dataset.startsAt))} – ${this.clock(state.endsAt)}`
      return
    }
    const ends = new Date(state.endsAt.getTime() + state.minutes * 60000)
    await this.save(state.chip.dataset.shiftId, { ends_at: ends.toISOString() }, state.chip, state.chip.closest(".schedule-grid-cell"))
  }

  // ---- add / edit dialog ------------------------------------------------------------------

  cellClick(event) {
    if (!this.canWriteValue || event.target.closest(".shift-chip")) return
    const cell = event.currentTarget
    this.openDialog({ date: cell.dataset.date, employeeId: cell.dataset.employeeId || "open" })
  }

  addAnywhere() {
    const today = this.element.querySelector(".schedule-grid-today")?.dataset.date || this.weekValue
    this.openDialog({ date: today, employeeId: "open" })
  }

  openShift(event) {
    if (!this.canWriteValue || event.target.closest(".shift-chip-resize")) return
    event.stopPropagation()
    this.openDialog({ chip: event.currentTarget })
  }

  keyShift(event) {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      this.openDialog({ chip: event.currentTarget })
    }
  }

  openDialog({ chip, date, employeeId }) {
    if (!this.hasDialogTarget) return
    this.errorTarget.classList.add("hidden")
    if (chip) {
      const start = new Date(chip.dataset.startsAt)
      const end = new Date(chip.dataset.endsAt)
      this.dialogTitleTarget.textContent = "Edit shift"
      this.fieldIdTarget.value = chip.dataset.shiftId
      this.fieldDateTarget.value = chip.dataset.date
      this.fieldEmployeeTarget.value = chip.dataset.employeeId || "open"
      this.fieldStartTarget.value = this.inputTime(start)
      this.fieldEndTarget.value = this.inputTime(end)
      this.fieldPositionTarget.value = chip.dataset.positionId || ""
      this.fieldBreakTarget.value = chip.dataset.breakMinutes || 0
      this.fieldRoleTarget.value = chip.dataset.role || ""
      if (this.hasFieldLocationTarget && chip.dataset.locationId) this.fieldLocationTarget.value = chip.dataset.locationId
      this.fieldNotesTarget.value = chip.dataset.notes || ""
      this.removeButtonTarget.classList.remove("hidden")
      this.removeButtonTarget.textContent = chip.dataset.published === "true" ? "Cancel shift" : "Remove"
    } else {
      this.dialogTitleTarget.textContent = "Add shift"
      this.fieldIdTarget.value = ""
      this.fieldDateTarget.value = date
      this.fieldEmployeeTarget.value = employeeId
      if (!this.fieldStartTarget.value) this.fieldStartTarget.value = "09:00"
      if (!this.fieldEndTarget.value) this.fieldEndTarget.value = "17:00"
      this.fieldRoleTarget.value = ""
      this.fieldNotesTarget.value = ""
      this.removeButtonTarget.classList.add("hidden")
    }
    this.dialogTarget.showModal()
    this.fieldStartTarget.focus()
  }

  closeDialog() {
    this.dialogTarget.close()
  }

  async submitForm(event) {
    event.preventDefault()
    const id = this.fieldIdTarget.value
    const date = this.fieldDateTarget.value
    const startsAt = this.combine(date, this.fieldStartTarget.value)
    let endsAt = this.combine(date, this.fieldEndTarget.value)
    if (endsAt <= startsAt) endsAt = new Date(endsAt.getTime() + 24 * 3600000)
    const payload = {
      employee_id: this.fieldEmployeeTarget.value,
      starts_at: startsAt.toISOString(),
      ends_at: endsAt.toISOString(),
      position_id: this.fieldPositionTarget.value,
      break_minutes: this.fieldBreakTarget.value,
      role_label: this.fieldRoleTarget.value,
      notes: this.fieldNotesTarget.value,
      location_id: this.hasFieldLocationTarget ? this.fieldLocationTarget.value : this.locationValue
    }
    this.saveButtonTarget.disabled = true
    this.saveButtonTarget.textContent = "Saving…"
    const chip = id ? this.element.querySelector(`.shift-chip[data-shift-id="${id}"]`) : null
    const ok = await this.save(id, payload, chip, this.cellFor(payload.employee_id, date))
    this.saveButtonTarget.disabled = false
    this.saveButtonTarget.textContent = "Save"
    if (ok) this.closeDialog()
  }

  async removeShift() {
    const id = this.fieldIdTarget.value
    if (!id) return
    const chip = this.element.querySelector(`.shift-chip[data-shift-id="${id}"]`)
    const published = chip?.dataset.published === "true"
    if (!window.confirm(published ? "Cancel this posted shift? The person is told." : "Remove this draft shift?")) return
    const response = await fetch(this.shiftUrl(id), { method: "DELETE", headers: this.headers(), credentials: "same-origin" })
    if (response.ok) {
      chip?.remove()
      this.announce(published ? "Shift cancelled." : "Shift removed.")
      this.closeDialog()
      this.refreshRowHours()
    } else {
      this.showError("Could not remove the shift.")
    }
  }

  // ---- server -------------------------------------------------------------------------------

  async save(id, payload, chip, cell) {
    const url = id ? this.shiftUrl(id) : this.createUrlValue
    const query = this.locationValue ? `?location_id=${encodeURIComponent(this.locationValue)}` : ""
    const response = await fetch(url + query, {
      method: id ? "PATCH" : "POST",
      headers: this.headers(),
      credentials: "same-origin",
      body: JSON.stringify({ scheduled_shift: payload })
    })
    const data = await response.json().catch(() => ({}))
    if (!response.ok) {
      this.showError(data.error || "Could not save the shift.")
      if (chip) this.restoreChip(chip)
      return false
    }
    const template = document.createElement("template")
    template.innerHTML = data.html.trim()
    const fresh = template.content.firstElementChild
    if (chip) chip.remove()
    const target = cell || this.cellFor(data.employee_id, data.date)
    if (target) target.appendChild(fresh)
    this.updateLabor(data.labor)
    this.refreshRowHours()
    const warnings = (data.warnings || []).map((w) => w.label).join(", ")
    this.announce(`Shift saved${warnings ? `. ${warnings}` : ""}.`)
    return true
  }

  restoreChip(chip) {
    chip.querySelector(".shift-chip-time").textContent = `${this.clock(new Date(chip.dataset.startsAt))} – ${this.clock(new Date(chip.dataset.endsAt))}`
  }

  showError(message) {
    if (this.hasDialogTarget && this.dialogTarget.open) {
      this.errorTarget.textContent = message
      this.errorTarget.classList.remove("hidden")
    } else {
      window.dispatchEvent(new CustomEvent("rupert:toast", { detail: { message, tone: "alert" } }))
      this.announce(message)
    }
  }

  updateLabor(labor) {
    if (!labor) return
    const money = (cents) => (cents / 100).toLocaleString(undefined, { style: "currency", currency: "USD" })
    const hours = (h) => `${Math.round(h * 100) / 100} h`
    if (this.hasLaborTarget) {
      this.laborTarget.querySelector('[data-labor="hours"]').textContent = hours(labor.total.hours)
      this.laborTarget.querySelector('[data-labor="cost"]').textContent = money(labor.total.cost_cents)
      this.laborTarget.querySelector('[data-labor="sales"]').textContent = money(labor.total.sales_cents)
      this.laborTarget.querySelector('[data-labor="percent"]').textContent = labor.total.percent == null ? "–" : `${labor.total.percent}%`
    }
    Object.entries(labor.days || {}).forEach(([date, row]) => {
      const el = this.element.querySelector(`[data-day-labor="${date}"]`)
      if (el) el.textContent = `${hours(row.hours)} · ${row.percent == null ? money(row.cost_cents) : `${row.percent}%`}`
    })
  }

  refreshRowHours() {
    this.element.querySelectorAll(".schedule-grid-row").forEach((row) => {
      const total = Array.from(row.querySelectorAll(".shift-chip")).reduce((sum, chip) => sum + (new Date(chip.dataset.endsAt) - new Date(chip.dataset.startsAt)) / 3600000, 0)
      const cell = row.querySelector("[data-row-hours]")
      if (cell) cell.textContent = `${Math.round(total * 100) / 100}`
    })
  }

  cellFor(employeeId, date) {
    const id = employeeId === "open" || employeeId == null ? "" : String(employeeId)
    return this.element.querySelector(`.schedule-grid-cell[data-employee-id="${id}"][data-date="${date}"]`)
  }

  shiftUrl(id) {
    return `${this.createUrlValue.replace(/\.json$/, "")}/${id}.json`
  }

  headers() {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    return { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": token || "" }
  }

  combine(date, time) {
    const [y, m, d] = date.split("-").map(Number)
    const [hh, mm] = time.split(":").map(Number)
    return new Date(y, m - 1, d, hh, mm, 0, 0)
  }

  inputTime(date) {
    return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`
  }

  clock(date) {
    return date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
  }

  announce(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
