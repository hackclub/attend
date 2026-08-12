import { Controller } from "@hotwired/stimulus"

// Shows/hides panels based on the checked radio or checkbox in scope.
// Radios: a panel with data-show-when="<value>" is shown when the radio
// with that value is selected. Checkboxes: use data-show-when="checked".
export default class extends Controller {
  static targets = ["input", "panel"]

  connect() {
    this.update()
  }

  update() {
    const checked = this.inputTargets.find(input => input.checked)
    const value = checked ? (checked.type === "checkbox" ? "checked" : checked.value) : null

    this.panelTargets.forEach(panel => {
      panel.classList.toggle("hidden", panel.dataset.showWhen !== value)
    })
  }
}
