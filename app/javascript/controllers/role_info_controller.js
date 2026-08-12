import { Controller } from "@hotwired/stimulus"

// Shows the permission breakdown for the role currently selected in the
// associated <select>, hiding the panels for the other roles.
export default class extends Controller {
  static targets = ["select", "panel"]

  connect() {
    this.update()
  }

  update() {
    const role = this.selectTarget.value
    this.panelTargets.forEach((panel) => {
      panel.classList.toggle("hidden", panel.dataset.role !== role)
    })
  }
}
