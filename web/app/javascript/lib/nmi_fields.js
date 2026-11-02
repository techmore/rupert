// Hosted fields only. Never read card inputs or submit card details to Rupert.
// Collect.js tokens are accepted by NMI's Payment API (payment_token).
// Only NMI's two fixed Collect.js hosts are loaded, matched to the environment.
const NMI_SCRIPTS = { sandbox: "https://sandbox.nmi.com/token/Collect.js", production: "https://secure.nmi.com/token/Collect.js" }
export async function mountNmiFields(config, { onReady, onToken, onError, signal }) {
  const src = NMI_SCRIPTS[config.sandbox === true ? "sandbox" : config.sandbox === false ? "production" : ""]
  if (!src || config.script_url !== src || !config.tokenization_key) throw new Error("NMI card fields are not set up for this checkout.")
  const identity = `${src}:${config.tokenization_key}`
  if (window.rupertNmiIdentity && window.rupertNmiIdentity !== identity) throw new Error("NMI account changed. Reload this screen.")
  if (!window.rupertNmiScript) {
    window.rupertNmiIdentity = identity
    window.rupertNmiScript = new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = src
      script.setAttribute("data-tokenization-key", config.tokenization_key)
      script.setAttribute("data-variant", "inline")
      const timer = setTimeout(() => { script.remove(); reject(new Error("NMI hosted fields could not load. Reload to retry.")) }, 10000)
      script.onload = () => { clearTimeout(timer); resolve() }
      script.onerror = () => { clearTimeout(timer); script.remove(); reject(new Error("NMI hosted fields could not load. Reload to retry.")) }
      document.head.append(script)
    })
  }
  await window.rupertNmiScript
  if (signal?.aborted) throw new Error("This checkout has closed.")
  if (!window.CollectJS?.configure || !window.CollectJS?.startPaymentRequest) throw new Error("NMI hosted fields are unavailable.")
  let active = true
  window.CollectJS.configure({
    variant: "inline",
    fields: {
      ccnumber: { selector: "#nmi-card-number", title: "Card number" },
      ccexp: { selector: "#nmi-card-exp", title: "Expiry" },
      cvv: { selector: "#nmi-card-cvv", title: "Security code" }
    },
    fieldsAvailableCallback: () => { if (active && !signal?.aborted) onReady() },
    validationCallback: (_field, valid) => { if (active && !signal?.aborted && !valid) onError("Check the card details in the secure fields.") },
    timeoutDuration: 10000,
    timeoutCallback: () => { if (active && !signal?.aborted) onError("Card tokenization timed out. No payment was submitted.") },
    callback: response => {
      if (!active || signal?.aborted) return
      if (typeof response?.token !== "string" || !/^[A-Za-z0-9_-]{10,4096}$/.test(response.token)) { onError("Card details could not be tokenized. No payment was submitted."); return }
      onToken(response.token)
    }
  })
  return {
    pay() { if (active && !signal?.aborted) window.CollectJS.startPaymentRequest() },
    destroy() { active = false }
  }
}
