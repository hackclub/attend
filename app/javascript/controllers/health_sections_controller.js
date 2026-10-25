import { Controller } from "@hotwired/stimulus"

const PLACEHOLDERS = new Set([ "n/a", "na", "not applicable" ])

export default class extends Controller {
  connect() {
    this.handleDetailsChanged = this.handleDetailsChanged.bind(this)
    this.element.addEventListener("input", this.handleDetailsChanged)
    this.element.addEventListener("change", this.handleDetailsChanged)
    this.element.querySelectorAll('[data-health-sections-target="section"]').forEach((section) => {
      this.updateSection(section)
    })
  }

  disconnect() {
    this.element.removeEventListener("input", this.handleDetailsChanged)
    this.element.removeEventListener("change", this.handleDetailsChanged)
  }

  responseChanged(event) {
    const section = event.target.closest('[data-health-sections-target="section"]')
    if (section) this.updateSection(section)
  }

  handleDetailsChanged(event) {
    const section = event.target.closest?.('[data-health-sections-target="section"]')
    if (section) this.updateSection(section)
  }

  normalizePlaceholder(event) {
    const input = event.target
    if (!PLACEHOLDERS.has(input.value.trim().toLowerCase())) return

    input.value = ""
    const section = input.closest('[data-health-sections-target="section"]')
    const explanation = section?.querySelector('[data-health-sections-target="explanation"]')
    if (explanation) explanation.textContent = '“n/a” was treated as no additional details.'
    input.dispatchEvent(new Event("change", { bubbles: true }))
  }

  updateSection(section) {
    const selected = section.querySelector('input[name$="[section_response]"]:checked')?.value
    const details = section.querySelector('[data-health-sections-target="details"]')
    const clearControl = section.querySelector('[data-health-sections-target="clearControl"]')
    const summary = section.querySelector('[data-health-sections-target="summary"]')
    const hasDetails = this.sectionHasCurrentDetails(section)

    if (selected === "nothing_to_add" && hasDetails) {
      details?.classList.remove("hidden")
      clearControl?.classList.remove("hidden")
    } else {
      details?.classList.toggle("hidden", selected !== "details" && selected !== "private")
      clearControl?.classList.add("hidden")
    }

    if (summary && selected) {
      summary.textContent = selected === "nothing_to_add" && hasDetails
        ? "Clear saved details to confirm nothing to add"
        : {
        nothing_to_add: "Nothing to add",
        details: "Add details",
        private: "Prefer to discuss privately"
        }[selected]
    }
  }

  sectionHasCurrentDetails(section) {
    if (section.dataset.hasDetails === "true") return true

    const valueFields = section.querySelectorAll(
      'textarea, select, input:not([type="hidden"]):not([type="radio"]):not([type="checkbox"])'
    )
    if ([ ...valueFields ].some((field) => field.value.trim() !== "")) return true

    return [ ...section.querySelectorAll('input[type="checkbox"]') ].some((field) => {
      return field.checked && !field.closest('[data-health-sections-target="clearControl"]')
    })
  }
}
