import { Controller } from "@hotwired/stimulus"

// Live-checks an email field against the domains we actually control, so an
// admin sees "must be a @hackclub.com address" while typing instead of losing
// the form to a failed save. Mirrors Event::SUPPORT_EMAIL_FORMAT — the server
// validation stays the source of truth.
export default class extends Controller {
  static targets = ["input", "message"]
  static values = { domains: Array }

  connect() {
    this.validate()
  }

  disconnect() {
    this.inputTarget.setCustomValidity("")
  }

  validate() {
    const value = this.inputTarget.value.trim()
    const domain = value.split("@")[1]

    // Stay quiet until there's a domain to judge: empty is the `required`
    // attribute's business, and half-typed addresses aren't wrong yet.
    if (!domain) {
      this.clear()
      return
    }

    if (this.domainsValue.some((allowed) => domain.toLowerCase() === allowed.toLowerCase())) {
      this.clear()
    } else {
      this.reject()
    }
  }

  clear() {
    this.inputTarget.setCustomValidity("")
    this.inputTarget.classList.remove("border-red-500", "focus:border-red-500", "focus:ring-red-500")
    if (this.hasMessageTarget) {
      this.messageTarget.textContent = ""
      this.messageTarget.classList.add("hidden")
    }
  }

  reject() {
    this.inputTarget.setCustomValidity(this.errorMessage)
    this.inputTarget.classList.add("border-red-500", "focus:border-red-500", "focus:ring-red-500")
    if (this.hasMessageTarget) {
      this.messageTarget.textContent = this.errorMessage
      this.messageTarget.classList.remove("hidden")
    }
  }

  get errorMessage() {
    const domains = this.domainsValue.map((domain) => `@${domain}`)
    const list = domains.length > 1
      ? `${domains.slice(0, -1).join(", ")} or ${domains[domains.length - 1]}`
      : domains[0]
    return `Must be a ${list} address.`
  }
}
