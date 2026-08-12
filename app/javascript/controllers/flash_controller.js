import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container"]

  dismiss() {
    this.element.remove()
  }
}
