import { Controller } from "@hotwired/stimulus"

// Toggles the electronic (DocuSeal template ID) vs physical (PDF upload +
// description) fields on the admin custom document form.
export default class extends Controller {
  static targets = ["electronic", "physical"]

  connect() {
    this.toggle()
  }

  toggle() {
    const selected = this.element.querySelector('input[name*="[document_kind]"]:checked')
    const physical = selected?.value === "physical"

    this.electronicTargets.forEach((el) => this.#setVisible(el, !physical))
    this.physicalTargets.forEach((el) => this.#setVisible(el, physical))
  }

  #setVisible(el, visible) {
    el.classList.toggle("hidden", !visible)
    // Disable hidden inputs so `required` doesn't block submission and
    // irrelevant values aren't submitted.
    el.querySelectorAll("input, select, textarea").forEach((input) => {
      input.disabled = !visible
    })
  }
}
