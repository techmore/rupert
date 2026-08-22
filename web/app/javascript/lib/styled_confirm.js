// Styled replacement for window.confirm, wired into Turbo's confirmation
// pipeline (Rails `data: { confirm: "..." }` attributes). Shows a modal that
// matches the app design system instead of the browser chrome dialog.
//
// The message text is used verbatim; destructive verbs in the copy keep their
// meaning. Escape cancels, Enter confirms (focus starts on Cancel so an
// impatient double-Enter can't accidentally approve).

let activeResolve = null

function ensureModal() {
  let modal = document.getElementById("rupert-confirm")
  if (modal) return modal

  modal = document.createElement("div")
  modal.id = "rupert-confirm"
  modal.className = "fixed inset-0 z-[100] hidden items-center justify-center px-4"
  modal.setAttribute("role", "dialog")
  modal.setAttribute("aria-modal", "true")
  modal.setAttribute("aria-labelledby", "rupert-confirm-message")
  modal.innerHTML = `
    <div class="fixed inset-0 bg-ink/40" data-confirm-backdrop></div>
    <div class="relative w-full max-w-md rounded-2xl border border-fog bg-paper p-6 shadow-[0_8px_30px_rgba(26,57,61,0.25)]">
      <h2 class="font-display text-lg text-ink">Are you sure?</h2>
      <p id="rupert-confirm-message" class="mt-2 text-sm leading-relaxed text-mocha"></p>
      <div class="mt-5 flex items-center justify-end gap-2">
        <button type="button" data-confirm-cancel
          class="inline-flex items-center rounded-full px-4 py-2 text-sm font-semibold border border-fog bg-paper text-ink hover:border-taupe focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-olive">Cancel</button>
        <button type="button" data-confirm-ok
          class="inline-flex items-center rounded-full px-4 py-2 text-sm font-semibold bg-olive text-cream hover:bg-olive-deep focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-olive focus-visible:ring-offset-2">Confirm</button>
      </div>
    </div>`
  document.body.appendChild(modal)

  modal.querySelector("[data-confirm-cancel]").addEventListener("click", () => settle(false))
  modal.querySelector("[data-confirm-backdrop]").addEventListener("click", () => settle(false))
  modal.querySelector("[data-confirm-ok]").addEventListener("click", () => settle(true))
  return modal
}

function settle(answer) {
  const modal = document.getElementById("rupert-confirm")
  if (!modal) return
  modal.classList.add("hidden")
  modal.classList.remove("flex")
  document.removeEventListener("keydown", onKeydown)
  if (activeResolve) {
    activeResolve(answer)
    activeResolve = null
  }
}

function onKeydown(e) {
  if (e.key === "Escape") settle(false)
}

// Turbo ≥7.2: Turbo.config.forms.confirm. Older: Turbo.setConfirmMethod.
export function registerStyledConfirm(Turbo) {
  const confirmMethod = (message) => {
    const modal = ensureModal()
    modal.querySelector("#rupert-confirm-message").textContent = message
    modal.classList.remove("hidden")
    modal.classList.add("flex")
    modal.querySelector("[data-confirm-cancel]").focus()
    document.addEventListener("keydown", onKeydown)
    return new Promise((resolve) => { activeResolve = resolve })
  }

  if (Turbo.session) {
    // Turbo 7.2+ native API
    Turbo.config.forms.confirm = confirmMethod
  } else if (typeof Turbo.setConfirmMethod === "function") {
    Turbo.setConfirmMethod(confirmMethod)
  }
}
