import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container"]
  static values = { reveal: Boolean }

  // Pages that morph keep their scroll position (the participant list), so a
  // notice for a button further down would land out of view. Bring it in.
  connect() {
    if (this.revealValue) this.element.scrollIntoView({ block: "nearest" })
  }

  dismiss() {
    this.element.remove()
  }
}
