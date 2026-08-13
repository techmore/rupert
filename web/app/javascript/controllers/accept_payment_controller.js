import { Controller } from "@hotwired/stimulus"

// Accept.js payment tokenization for the public warehouse checkout. Card data
// is entered into Authorize.net hosted-field iframes and tokenized into a
// payment nonce before the form submits, so the server only ever sees a nonce.
export default class extends Controller {
  static targets = ["cardNumber", "expiration", "cardCode", "nonce", "descriptor", "error", "submit"]
  static values = { loginId: String, clientKey: String, sandbox: Boolean }

  connect() {
    this.submitTarget.disabled = true
    this.loadScript()
      .then(() => this.initFields())
      .catch(() => this.showError("The payment library could not load. Please try again."))
  }

  loadScript() {
    if (window.Accept) return Promise.resolve()
    const src = this.sandboxValue
      ? "https://jstest.authorize.net/v1/Accept.js"
      : "https://js.authorize.net/v1/Accept.js"
    return new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = src
      script.onload = resolve
      script.onerror = reject
      document.head.appendChild(script)
    })
  }

  initFields() {
    this.fields = window.Accept.HOSTED_FIELDS.initialize({
      apiLoginID: this.loginIdValue,
      clientKey: this.clientKeyValue,
      payment: { allowCard: true },
      fields: {
        cardNumber: { target: `#${this.cardNumberTarget.id}`, placeholder: "Card number" },
        expirationDate: { target: `#${this.expirationTarget.id}`, placeholder: "MM / YY" },
        cardCode: { target: `#${this.cardCodeTarget.id}`, placeholder: "CVC" },
      },
      responseHandler: (response) => this.onResponse(response),
    })
    this.submitTarget.disabled = false
  }

  onResponse(response) {
    if (response.messages.resultCode === "Error") {
      this.showError(response.messages.message[0].text)
      return
    }
    this.nonceTarget.value = response.opaqueData.dataValue
    this.descriptorTarget.value = response.opaqueData.dataDescriptor
    this.element.requestSubmit()
  }

  submit(event) {
    if (this.nonceTarget.value || !this.fields) return
    event.preventDefault()
    this.hideError()
    this.submitTarget.disabled = true
    this.fields.submit()
  }

  showError(message) {
    this.errorTarget.textContent = message
    this.submitTarget.disabled = false
  }

  hideError() {
    this.errorTarget.textContent = ""
  }
}
