import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal"]

  showConfirmation() {
    this.modalTarget.classList.remove("hidden")
  }

  hideConfirmation() {
    this.modalTarget.classList.add("hidden")
  }
}
