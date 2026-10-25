import { Controller } from "@hotwired/stimulus"
import { html, safeMarkup } from "utils/html"
import { incompleteDateTimeMessage } from "utils/incomplete_date_time"

// Cloudscape's validation timing for console forms
// (cloudscape.design/patterns/general/errors/validation):
//
// - never on first load
// - on blur, when the field has a value, is half-typed (a date missing its
//   AM/PM) or is required and was left empty
// - on every keypress while a field is in error (so the message clears live)
// - on submit: show every client-side error, focus the top-most one and stop
//   the submit. Server errors don't block; the server stays authoritative.
// - after a failed submit (a 422 re-render), focus the first invalid control
//
// It reads the constraints already on the controls (required, type=email/url,
// pattern, minlength/maxlength, min/max, step) and these optional data
// attributes for wording and checks native attributes can't express:
//
//   data-cs-required-message   replaces "[Label] is required."
//   data-cs-type-message       replaces the email/url/number format message
//   data-cs-pattern-message    replaces "Enter a valid [label]."
//   data-cs-range-message      replaces the min/max message
//   data-cs-example            appended as " For example: …" to format errors
//   data-cs-maxlength          a character limit shown as an error rather
//                              than enforced by blocking typing
//   data-cs-allowed-domains    JSON list; an email must end in one of them
//   data-cs-domain-message     replaces the allowed-domains message
//   data-cs-after              id of a control this one's value must follow
//   data-cs-after-message      message when it doesn't
//   data-cs-warning-pattern    regex; a match shows data-cs-warning-message
//   data-cs-warning-maxlength  a soft limit; past it shows
//                              data-cs-warning-message ({count}, {max})
//
// Labels come from the field wrapper's data-cs-label (cs_form_field renders
// it), else the control's <label>. Error elements go under the control,
// before the constraint text, with aria-invalid and aria-describedby kept in
// step. Submit buttons with formnovalidate skip the client-side checks.
const ICONS = {
  error: '<circle cx="8" cy="8" r="7"/><path d="M5.5 5.5l5 5m0-5l-5 5"/>',
  warning: '<path d="M8 1.5l7 12.5H1z"/><path d="M8 6v4m0 1.8v.2"/>'
}

const SKIPPED_TYPES = new Set(["hidden", "submit", "button", "reset", "image"])
const CHOICE_TYPES = new Set(["checkbox", "radio", "file"])

let generatedIds = 0

export default class extends Controller {
  connect() {
    this.element.noValidate = true
    this.onFocusOut = this.focusOut.bind(this)
    this.onInput = this.input.bind(this)
    this.onChange = this.change.bind(this)
    this.onSubmit = this.submit.bind(this)
    this.element.addEventListener("focusout", this.onFocusOut)
    this.element.addEventListener("input", this.onInput)
    this.element.addEventListener("change", this.onChange)
    this.element.addEventListener("submit", this.onSubmit)
    this.focusServerErrors()
  }

  disconnect() {
    this.element.removeEventListener("focusout", this.onFocusOut)
    this.element.removeEventListener("input", this.onInput)
    this.element.removeEventListener("change", this.onChange)
    this.element.removeEventListener("submit", this.onSubmit)
  }

  // Public: validate every control now (for wizard-style "Next" buttons that
  // don't submit). Returns true when there are no client-side errors.
  validateAll({ focus = true } = {}) {
    const invalid = this.controls.filter((control) => !this.validate(control))
    if (invalid.length && focus) this.focusControl(invalid[0])
    return invalid.length === 0
  }

  // Events --------------------------------------------------------------

  focusOut(event) {
    const control = event.target
    if (!this.isValidatable(control)) return
    if (CHOICE_TYPES.has(control.type)) return
    if (control.value.trim() !== "" || control.required || control.validity.badInput || this.isInError(control)) {
      this.validate(control)
    }
  }

  input(event) {
    const control = event.target
    if (!this.isValidatable(control)) return
    this.clearServerMessage(control)
    if (this.isInError(control) || this.hasWarningRules(control)) this.validate(control)
    this.revalidateDependents(control)
  }

  change(event) {
    const control = event.target
    if (!this.isValidatable(control)) return
    this.clearServerMessage(control)
    if (this.isInError(control) || CHOICE_TYPES.has(control.type) || control.tagName === "SELECT") {
      this.validate(control)
    }
    this.revalidateDependents(control)
  }

  submit(event) {
    if (event.submitter?.formNoValidate) return
    if (this.validateAll()) return

    event.preventDefault()
    event.stopImmediatePropagation()
  }

  // Validation ----------------------------------------------------------

  get controls() {
    return Array.from(this.element.elements).filter((control) => this.isValidatable(control))
  }

  isValidatable(control) {
    if (!control || !["INPUT", "SELECT", "TEXTAREA"].includes(control.tagName)) return false
    if (control.disabled || SKIPPED_TYPES.has(control.type)) return false
    // Removed nested rows and collapsed sections can't be fixed, so they
    // can't block a submit.
    if (control.closest("[hidden], .hidden, template")) return false
    return control.dataset.csValidate !== "false"
  }

  // Shows or clears this control's error (and warning). Returns true when
  // there's no client-side error.
  validate(control) {
    const message = this.errorFor(control)
    const controls = this.groupControls(control)

    if (message) {
      this.showMessage(control, "error", message)
      controls.forEach((each) => each.setAttribute("aria-invalid", "true"))
      this.removeMessage(control, "warning")
      return false
    }

    this.removeMessage(control, "error")
    controls.forEach((each) => each.removeAttribute("aria-invalid"))
    const warning = this.warningFor(control)
    if (warning) {
      this.showMessage(control, "warning", warning)
    } else if (this.hasWarningRules(control)) {
      this.removeMessage(control, "warning")
    }
    return true
  }

  errorFor(control) {
    const data = control.dataset
    const validity = control.validity
    const label = this.labelFor(control)
    const thing = this.inSentence(label)
    const example = data.csExample ? ` For example: ${data.csExample}` : ""
    const value = control.value

    if (validity.valueMissing) return data.csRequiredMessage || `${label} is required.`

    if (validity.badInput) {
      if (data.csTypeMessage) return data.csTypeMessage
      if (control.type === "number") return "Enter a valid number."
      return incompleteDateTimeMessage(control) || `Enter a valid ${thing}.${example}`
    }

    if (validity.typeMismatch) {
      if (data.csTypeMessage) return data.csTypeMessage
      if (control.type === "email") return `Enter a valid email address.${example}`
      if (control.type === "url") return `Enter a valid URL. For example: ${data.csExample || "https://example.com"}`
      return `Enter a valid ${thing}.${example}`
    }

    if (validity.patternMismatch) return data.csPatternMessage || `Enter a valid ${thing}.${example}`

    const maxLength = Number(data.csMaxlength) || (control.maxLength > 0 ? control.maxLength : 0)
    if (maxLength && value.length > maxLength) {
      return `The ${thing} has too many characters. Character count: ${value.length}/${maxLength}.`
    }

    if (validity.tooShort) {
      return `The ${thing} has too few characters. Character count: ${value.length}/${control.minLength}.`
    }

    if (validity.rangeUnderflow) return data.csRangeMessage || this.rangeMessage(control, "min")
    if (validity.rangeOverflow) return data.csRangeMessage || this.rangeMessage(control, "max")

    if (validity.stepMismatch) {
      return control.type === "number" && Number(control.step || 1) === 1 ? "Enter a whole number." : `Enter a valid ${thing}.`
    }

    if (data.csAllowedDomains && value.trim() !== "" && value.includes("@")) {
      const domains = JSON.parse(data.csAllowedDomains)
      const domain = value.trim().split("@").pop().toLowerCase()
      if (!domains.some((allowed) => allowed.toLowerCase() === domain)) {
        return data.csDomainMessage || `Enter an email address ending in ${this.listOf(domains.map((d) => `@${d}`))}.`
      }
    }

    if (data.csAfter && value !== "") {
      const other = document.getElementById(data.csAfter)
      if (other && other.value !== "" && value <= other.value) {
        return data.csAfterMessage || `${label} must be after ${this.inSentence(this.labelFor(other))}.`
      }
    }

    // A message another controller set with setCustomValidity.
    if (validity.customError) return control.validationMessage

    return null
  }

  warningFor(control) {
    const data = control.dataset
    const value = control.value
    if (!data.csWarningMessage || value === "") return null

    if (data.csWarningPattern && new RegExp(data.csWarningPattern).test(value)) {
      return data.csWarningMessage
    }

    const softMax = Number(data.csWarningMaxlength)
    if (softMax && value.length > softMax) {
      return data.csWarningMessage.replace("{count}", value.length).replace("{max}", softMax)
    }

    return null
  }

  hasWarningRules(control) {
    return Boolean(control.dataset.csWarningMessage)
  }

  rangeMessage(control, bound) {
    const limit = control.getAttribute(bound)
    if (control.type === "number" || control.type === "range") {
      return bound === "min" ? `Enter a number of ${limit} or more.` : `Enter a number of ${limit} or less.`
    }
    return bound === "min" ? "Enter a later date." : "Enter an earlier date."
  }

  revalidateDependents(control) {
    if (!control.id) return
    this.controls
      .filter((other) => other.dataset.csAfter === control.id && this.isInError(other))
      .forEach((other) => this.validate(other))
  }

  // Markup --------------------------------------------------------------

  fieldFor(control) {
    return control.closest("[data-cs-field]") || control.closest(".cs-field") || control.parentElement
  }

  groupControls(control) {
    if (control.type === "radio" && control.name) {
      return Array.from(this.element.elements).filter((each) => each.type === "radio" && each.name === control.name)
    }
    return [control]
  }

  isInError(control) {
    return control.getAttribute("aria-invalid") === "true"
  }

  messageId(control, type) {
    const field = this.fieldFor(control)
    if (type === "error" && field.dataset.csErrorId) return field.dataset.csErrorId
    if (!control.id) control.id = `cs-control-${++generatedIds}`
    const base = field.dataset.csErrorId ? field.dataset.csErrorId.replace(/-error$/, "") : control.id
    return `${base}-${type}`
  }

  showMessage(control, type, message) {
    const id = this.messageId(control, type)
    const field = this.fieldFor(control)
    let element = document.getElementById(id)

    if (!element) {
      element = document.createElement("p")
      element.id = id
      element.className = `cs-field-${type}`
      const constraint = Array.from(field.children).find((child) => child.classList.contains("cs-field-hint"))
      field.insertBefore(element, constraint || null)
    }
    delete element.dataset.csServerError
    delete element.dataset.csServerWarning
    element.innerHTML = html`<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${safeMarkup(ICONS[type])}</svg><span>${message}</span>`

    this.groupControls(control).forEach((each) => this.describe(each, id, true))
  }

  removeMessage(control, type) {
    const id = this.messageId(control, type)
    document.getElementById(id)?.remove()
    this.groupControls(control).forEach((each) => this.describe(each, id, false))
  }

  // The server rendered this error for the value that was submitted; once
  // the person edits the field it no longer applies.
  clearServerMessage(control) {
    const id = this.messageId(control, "error")
    const element = document.getElementById(id)
    if (!element || element.dataset.csServerError === undefined) return
    element.remove()
    this.groupControls(control).forEach((each) => {
      this.describe(each, id, false)
      each.removeAttribute("aria-invalid")
    })
  }

  describe(control, id, add) {
    const ids = (control.getAttribute("aria-describedby") || "").split(/\s+/).filter(Boolean).filter((each) => each !== id)
    if (add) ids.unshift(id)
    if (ids.length) {
      control.setAttribute("aria-describedby", ids.join(" "))
    } else {
      control.removeAttribute("aria-describedby")
    }
  }

  // Labels --------------------------------------------------------------

  labelFor(control) {
    const field = this.fieldFor(control)
    if (field?.dataset.csLabel) return field.dataset.csLabel
    if (control.dataset.csLabel) return control.dataset.csLabel

    const label = control.labels?.[0] || field?.querySelector("legend")
    if (label) {
      const copy = label.cloneNode(true)
      copy.querySelectorAll(".cs-field-optional").forEach((node) => node.remove())
      const text = copy.textContent.trim()
      if (text) return text
    }
    return control.getAttribute("aria-label") || "This field"
  }

  inSentence(label) {
    if (label.length > 1 && /[A-Z]/.test(label[1])) return label
    return label.charAt(0).toLowerCase() + label.slice(1)
  }

  listOf(items) {
    if (items.length < 2) return items[0] || ""
    return `${items.slice(0, -1).join(", ")} or ${items[items.length - 1]}`
  }

  // Focus ---------------------------------------------------------------

  focusServerErrors() {
    // One form per page takes focus, and only the first time it renders.
    if (document.body.dataset.csErrorFocused) return
    const invalid = this.controls.find((control) => this.isInError(control))
    const alert = this.element.querySelector(".cs-form-error")
    if (!invalid && !alert) return

    document.body.dataset.csErrorFocused = "true"
    requestAnimationFrame(() => {
      if (invalid) {
        this.focusControl(invalid)
      } else {
        alert.scrollIntoView({ block: "center" })
        alert.focus({ preventScroll: true })
      }
    })
  }

  focusControl(control) {
    const target = this.isFocusable(control) ? control : this.fieldFor(control)?.querySelector("input:not([type=hidden]), select, textarea, button, [tabindex]")
    const scrollTarget = this.fieldFor(control) || control
    scrollTarget.scrollIntoView({ block: "center" })
    target?.focus({ preventScroll: true })
    // A click on the submit button can take focus back after the submit
    // event (Chrome does this for date inputs), so check again next frame.
    requestAnimationFrame(() => {
      if (target && document.activeElement !== target) target.focus({ preventScroll: true })
    })
  }

  isFocusable(control) {
    return control.getClientRects().length > 0 && getComputedStyle(control).visibility !== "hidden"
  }
}
