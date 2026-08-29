import { Controller } from "@hotwired/stimulus"

const ITI_VERSION = "25.3.1"
const ITI_BASE = `https://cdn.jsdelivr.net/npm/intl-tel-input@${ITI_VERSION}/build`

export default class extends Controller {
  static targets = ["input"]

  connect() {
    this.loadIntlTelInput()
      .then(() => this.initializeInputs())
      .catch(() => {
        // The CDN is unreachable. Server-side validation still rejects bad
        // numbers, so degrade to a plain text field rather than blocking.
        console.warn("[phone-input] intl-tel-input failed to load; falling back to server validation")
      })
  }

  // Injects the intl-tel-input CSS/JS on demand so pages without phone
  // inputs (i.e. most of the app) never pay for the CDN round-trips.
  // Keep the version pinned to match the utils import in loadUtils below.
  async loadIntlTelInput() {
    if (window.intlTelInput) return

    if (!document.querySelector("link[data-intl-tel-input]")) {
      const link = document.createElement("link")
      link.rel = "stylesheet"
      link.href = `${ITI_BASE}/css/intlTelInput.css`
      link.dataset.intlTelInput = "true"
      document.head.appendChild(link)
    }

    window._intlTelInputLoadPromise ||= new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = `${ITI_BASE}/js/intlTelInput.min.js`
      script.onload = resolve
      script.onerror = reject
      document.head.appendChild(script)
    })

    return window._intlTelInputLoadPromise
  }

  // Region subtag of the browser's locale ("en-AU" -> "au"), falling back to
  // US to match the server's PhoneNormalizer::DEFAULT_COUNTRY.
  localeCountry() {
    const locales = navigator.languages?.length ? navigator.languages : [ navigator.language ]

    for (const locale of locales) {
      if (!locale) continue

      try {
        // `maximize()` fills in the likely region for a bare language tag,
        // so "fr" resolves to FR rather than falling through to the default.
        const parsed = new Intl.Locale(locale)
        const region = parsed.region || parsed.maximize().region
        if (region) return region.toLowerCase()
      } catch {
        // Malformed locale string; try the next one.
      }
    }

    return "us"
  }

  get inputs() {
    return this.hasInputTarget
      ? this.inputTargets
      : Array.from(this.element.querySelectorAll('input[type="tel"]'))
  }

  initializeInputs() {
    this.inputs.forEach(input => {
      if (input.dataset.phoneInitialized) return
      if (!window.intlTelInput) return

      const iti = window.intlTelInput(input, {
        // Was `initialCountry: "auto"` with a geoIpLookup against ipapi.co.
        // That host is not in the CSP connect-src allowlist, so the fetch was
        // blocked and the catch fell back to "us" for *everyone* — which is a
        // direct cause of country-code-less numbers: someone abroad types their
        // national number under a US flag and it is stored as +1<national>.
        // The browser's own locale is a better guess, costs no request, and
        // doesn't send a reporter's IP to a third party from the confidential
        // incident-report form.
        initialCountry: this.localeCountry(),
        countryOrder: ["us", "gb", "ca", "au", "de", "at"],
        separateDialCode: true,
        nationalMode: true,
        // Explicit: intl-tel-input can restrict `isValidNumber()` to a set of
        // number types, and a MOBILE-only setting rejects every landline. SMS
        // matters, but a landline must still be storable — never narrow this.
        validationNumberTypes: null,
        // The dial code sits in its own chip, so any author-supplied E.164
        // placeholder would read as a doubled country code ("+1  +1555…").
        // Let the library show a national-format example for the country.
        autoPlaceholder: "aggressive",
        formatOnDisplay: true,
        showFlags: true,
        loadUtils: () => import(`${ITI_BASE}/js/utils.js`)
      })

      input.iti = iti
      // `isValidNumber()` needs utils; until they land it returns null and we
      // must not treat that as "invalid" or we'd block every submission.
      input.dataset.phoneUtilsReady = "false"
      iti.promise
        .then(() => { input.dataset.phoneUtilsReady = "true" })
        .catch(() => { input.dataset.phoneUtilsReady = "false" })

      // An existing server value is full E.164; hand it to the library so it
      // selects the right country and shows just the national part.
      if (input.value) {
        const initialValue = input.value
        iti.promise.then(() => iti.setNumber(initialValue)).catch(() => {})
      }

      // Pasting a full international number should re-select the country.
      input.addEventListener("paste", event => {
        const pasted = (event.clipboardData || window.clipboardData)?.getData("text")?.trim()
        if (!pasted || !pasted.startsWith("+")) return

        event.preventDefault()
        iti.setNumber(pasted)
        this.clearError(input)
      })

      input.addEventListener("input", () => this.clearError(input))
      input.addEventListener("blur", () => this.validateInput(input, { silent: false }))

      this.attachSubmitHandler(input)
      input.dataset.phoneInitialized = "true"
    })
  }

  attachSubmitHandler(input) {
    const form = input.closest("form")
    if (!form || form.dataset.phoneSubmitHandlerAttached) return

    form.dataset.phoneSubmitHandlerAttached = "true"
    form.addEventListener("submit", event => {
      let firstInvalid = null

      form.querySelectorAll('input[type="tel"]').forEach(telInput => {
        if (!telInput.iti) return

        const ok = this.validateInput(telInput, { silent: false })
        if (!ok && !firstInvalid) firstInvalid = telInput
        // Rewrite to E.164 whether or not the whole form submits: if it does
        // go through, the server must never receive bare national digits.
        this.writeE164(telInput)
      })

      if (firstInvalid) {
        event.preventDefault()
        event.stopPropagation()
        firstInvalid.focus()
      }
    })
  }

  // Replaces the visible national-format value with the full E.164 number.
  // `separateDialCode` keeps the dial code out of the field, so submitting the
  // raw value is what produced country-code-less numbers like "0555550100".
  writeE164(input) {
    const iti = input.iti
    if (!iti || !input.value.trim()) return

    const number = iti.getNumber()
    if (number && number.startsWith("+")) {
      input.value = number
      return
    }

    // Utils never loaded, so `getNumber()` can't build E.164. Prefix the
    // selected country's dial code by hand rather than sending bare digits.
    const dialCode = iti.getSelectedCountryData()?.dialCode
    const digits = input.value.replace(/\D/g, "").replace(/^0+/, "")
    if (dialCode && digits) input.value = `+${dialCode}${digits}`
  }

  // Returns true when the field may be submitted.
  validateInput(input, { silent }) {
    const iti = input.iti
    if (!iti) return true

    const filled = input.value.trim().length > 0
    if (!filled) {
      this.clearError(input)
      return !input.required
    }

    // Without utils there is nothing trustworthy to check against; let the
    // server be the gate instead of guessing.
    if (input.dataset.phoneUtilsReady !== "true") {
      this.clearError(input)
      return true
    }

    if (this.looksDialable(iti)) {
      this.clearError(input)
      return true
    }

    if (!silent) this.showError(input, "Enter a valid phone number, including the country code.")
    return false
  }

  // Mirrors the server's Phonelib `valid?` as closely as the browser allows.
  //
  // `isValidNumber()` alone is only a length check since intl-tel-input v24, so
  // it happily accepts a national number that lost its country code (typing
  // "0555550100" with the US flag selected yields "+10555550100"). Requiring a
  // known number type closes that gap: libphonenumber can't classify a number
  // that matches no real range, so those come back UNKNOWN (-1).
  //
  // `isValidNumberPrecise()` is NOT the answer here — it only accepts numbers
  // typed as MOBILE, so it rejects every landline, and every US number, which
  // libphonenumber classes as FIXED_LINE_OR_MOBILE.
  looksDialable(iti) {
    if (!iti.isValidNumber()) return false

    return typeof iti.getNumberType === "function" ? iti.getNumberType() !== -1 : true
  }

  showError(input, message) {
    input.setAttribute("aria-invalid", "true")
    input.classList.add("border-red-500")

    let error = this.errorElementFor(input)
    if (!error) {
      error = document.createElement("p")
      error.dataset.phoneError = "true"
      error.className = "mt-1 text-sm text-red-600"
      error.setAttribute("role", "alert")
      const container = input.closest(".iti") || input
      container.insertAdjacentElement("afterend", error)
    }
    error.textContent = message
  }

  clearError(input) {
    input.removeAttribute("aria-invalid")
    input.classList.remove("border-red-500")
    this.errorElementFor(input)?.remove()
  }

  errorElementFor(input) {
    const container = input.closest(".iti") || input
    const next = container.nextElementSibling
    return next?.dataset?.phoneError ? next : null
  }

  disconnect() {
    this.inputs.forEach(input => {
      this.clearError(input)
      if (input.iti) {
        input.iti.destroy()
        delete input.iti
      }
      delete input.dataset.phoneInitialized
      delete input.dataset.phoneUtilsReady
    })
  }
}
