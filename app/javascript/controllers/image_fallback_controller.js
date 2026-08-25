import { Controller } from "@hotwired/stimulus"

// Hides an image that fails to load. Replaces onerror="this.style.display='none'",
// which a Content-Security-Policy without `unsafe-inline` blocks.
export default class extends Controller {
  connect() {
    // A broken src can finish loading before Stimulus connects, in which case
    // no error event is coming — check for it.
    if (this.element.complete && this.element.naturalWidth === 0) {
      this.hide()
      return
    }
    this.onError = () => this.hide()
    this.element.addEventListener("error", this.onError)
  }

  disconnect() {
    if (this.onError) this.element.removeEventListener("error", this.onError)
  }

  hide() {
    this.element.style.display = "none"
  }
}
