import { Controller } from "@hotwired/stimulus"

// Shows the medication section and "required" hints only when the incident
// category is medical, and the medication rows only when "dispensed" is ticked.
export default class extends Controller {
  static targets = ["category", "medicalOnly", "dispensed", "medications"]

  connect() {
    this.update()
  }

  update() {
    const medical = this.categoryTarget.value === "medical"
    this.medicalOnlyTargets.forEach(el => el.classList.toggle("hidden", !medical))

    if (this.hasMedicationsTarget) {
      const dispensed = medical && this.dispensedTarget.checked
      this.medicationsTarget.classList.toggle("hidden", !dispensed)
    }
  }
}
