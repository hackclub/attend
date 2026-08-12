import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input"]

  connect() {
    this.loadIntlTelInput().then(() => {
      this.initializeInputs()
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
      link.href = "https://cdn.jsdelivr.net/npm/intl-tel-input@25.3.1/build/css/intlTelInput.css"
      link.dataset.intlTelInput = "true"
      document.head.appendChild(link)
    }

    window._intlTelInputLoadPromise ||= new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = "https://cdn.jsdelivr.net/npm/intl-tel-input@25.3.1/build/js/intlTelInput.min.js"
      script.onload = resolve
      script.onerror = reject
      document.head.appendChild(script)
    })

    return window._intlTelInputLoadPromise
  }

  initializeInputs() {
    const inputs = this.hasInputTarget ? this.inputTargets : this.element.querySelectorAll('input[type="tel"]')
    
    inputs.forEach(input => {
      if (input.dataset.phoneInitialized) return
      if (!window.intlTelInput) return

      const iti = window.intlTelInput(input, {
        initialCountry: "auto",
        geoIpLookup: callback => {
          fetch("https://ipapi.co/json")
            .then(res => res.json())
            .then(data => callback(data.country_code))
            .catch(() => callback("us"))
        },
        countryOrder: ["us", "gb", "ca", "au", "de", "at"],
        separateDialCode: true,
        nationalMode: true,
        formatOnDisplay: true,
        showFlags: true,
        loadUtils: () => import("https://cdn.jsdelivr.net/npm/intl-tel-input@25.3.1/build/js/utils.js")
      })

      // If user pastes/types a full international number, let the library parse it
      input.addEventListener('input', () => {
        const val = input.value.trim()
        if (val.startsWith('+')) {
          iti.setNumber(val)
        }
      })

      // If input has an existing value (e.g., from server), parse it to set the country
      // and display only the national number (without the dial code prefix)
      // Wait for utils to load before parsing the number
      if (input.value) {
        const initialValue = input.value
        iti.promise.then(() => {
          iti.setNumber(initialValue)
        })
      }

      // Before form submission, replace input value with full E.164 number
      const form = input.closest('form')
      if (form && !form.dataset.phoneSubmitHandlerAttached) {
        form.dataset.phoneSubmitHandlerAttached = 'true'
        form.addEventListener('submit', () => {
          // Update all phone inputs with their full international numbers
          form.querySelectorAll('input[type="tel"]').forEach(telInput => {
            if (telInput.iti && telInput.iti.isValidNumber()) {
              telInput.value = telInput.iti.getNumber()
            }
          })
        })
      }

      input.dataset.phoneInitialized = "true"
      input.iti = iti
    })
  }

  disconnect() {
    const inputs = this.hasInputTarget ? this.inputTargets : this.element.querySelectorAll('input[type="tel"]')
    inputs.forEach(input => {
      if (input.iti) {
        input.iti.destroy()
        delete input.iti
      }
    })
  }
}
