// Global form busy state, applied to every <form> on every page without
// needing per-view data attributes. Capturing submit listener disables the
// submit button(s) and swaps their label to "Saving…" so slow saves never
// look like nothing happened. Turbo restores buttons on submit-end.
//
// Forms can opt out with data-busy="false" (e.g. search-as-you-type forms).

function armForm(form) {
  if (!form || form.dataset.busyArmed === "true") return
  if (form.dataset.busy === "false") return
  form.dataset.busyArmed = "true"
  form.addEventListener("submit", () => {
    if (form.dataset.busyActive === "true") return
    form.dataset.busyActive = "true"
    form.querySelectorAll("button[type=submit], input[type=submit]").forEach((btn) => {
      btn.dataset.busyLabel = btn.tagName === "INPUT" ? btn.value : btn.textContent
      btn.disabled = true
      if (btn.tagName === "INPUT") btn.value = "Saving…"
      else btn.textContent = "Saving…"
    })
  })
  form.addEventListener("turbo:submit-end", () => {
    delete form.dataset.busyActive
    form.querySelectorAll("button[type=submit], input[type=submit]").forEach((btn) => {
      if (btn.dataset.busyLabel === undefined) return
      btn.disabled = false
      if (btn.tagName === "INPUT") btn.value = btn.dataset.busyLabel
      else btn.textContent = btn.dataset.busyLabel
      delete btn.dataset.busyLabel
    })
  })
}

function armAll(root) {
  root.querySelectorAll("form").forEach(armForm)
}

armAll(document)
document.addEventListener("turbo:load", (e) => armAll(e.target || document))
document.addEventListener("turbo:frame-load", (e) => armAll(e.target || document))
