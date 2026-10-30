import { Controller } from "@hotwired/stimulus"

// Keeps what someone has typed into a form while a "refresh from your Hack
// Club account" button (the form with id `form`) takes them through Hack Club
// Auth and back, which reloads the page. Like incident_report_controller.js,
// but in this tab's sessionStorage rather than the server's session cookie,
// read back once, for the same `key` (who and which form) within 15 minutes.
//
// The fresh page wins where Hack Club Auth fills a field in: read-only ones,
// those named in `fromHackClub`, and any left as the page first showed them,
// since that's often what was refreshed. After a submission came back with
// errors (`submitted`), everything showing is what they sent, so all of it
// is kept.
export default class extends Controller {
  static values = { key: String, form: String, fromHackClub: Array, submitted: Boolean }

  static STORAGE_KEY = "refresh_draft"
  static MAX_AGE_MS = 15 * 60 * 1000
  static TYPES = [ "text", "email", "tel", "url", "number", "date", "textarea", "select-one" ]

  connect() {
    // Turbo's cached preview is replaced by the real page, which restores.
    if (document.documentElement.hasAttribute("data-turbo-preview")) return

    const draft = this.take()
    if (draft?.key !== this.keyValue || !(Date.now() - draft.savedAt < this.constructor.MAX_AGE_MS)) return

    this.fields().forEach((field) => {
      const value = draft.values?.[field.name]
      if (typeof value !== "string") return
      if (field.type === "select-one" && !Array.from(field.options).some((option) => option.value === value)) return

      field.value = value
    })
  }

  stash(event) {
    if (event.target.id !== this.formValue) return

    const values = {}
    this.fields()
      .filter((field) => this.submittedValue || this.changed(field))
      .forEach((field) => { values[field.name] = field.value })

    try {
      sessionStorage.setItem(this.constructor.STORAGE_KEY, JSON.stringify({ key: this.keyValue, savedAt: Date.now(), values }))
    } catch (_e) {
      // Storage full or turned off: the refresh still works, without the draft.
    }
  }

  // Whatever happens next, a draft is only ever read once.
  take() {
    try {
      const saved = sessionStorage.getItem(this.constructor.STORAGE_KEY)
      sessionStorage.removeItem(this.constructor.STORAGE_KEY)
      return JSON.parse(saved)
    } catch (_e) {
      return null
    }
  }

  fields() {
    return Array.from(this.element.elements).filter((field) =>
      field.name && !field.disabled && !field.readOnly &&
      this.constructor.TYPES.includes(field.type) &&
      !this.fromHackClubValue.includes(field.name)
    )
  }

  changed(field) {
    if (field.type !== "select-one") return field.value !== field.defaultValue

    const initial = Array.from(field.options).find((option) => option.defaultSelected) || field.options[0]
    return field.value !== (initial?.value ?? "")
  }
}
