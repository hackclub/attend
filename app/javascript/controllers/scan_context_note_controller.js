import { Controller } from "@hotwired/stimulus"

// Shows the chosen scan point's "When to use this" note under the scanner's
// scan point select. Each note is rendered once; only the selected one shows.
export default class extends Controller {
  static targets = ["select", "note"]

  connect() {
    this.show()
  }

  show() {
    const id = this.selectTarget.value
    this.noteTargets.forEach((note) => note.classList.toggle("hidden", note.dataset.scanContextId !== id))
  }
}
