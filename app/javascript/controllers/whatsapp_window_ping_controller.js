import { Controller } from "@hotwired/stimulus"

// Inbound WhatsApp messages reopen the 24-hour freeform reply window. They
// arrive over Turbo Streams, so each one announces itself and the composer's
// whatsapp-window controller re-enables the form without a page reload.
export default class extends Controller {
  static values = { at: String }

  connect() {
    window.dispatchEvent(
      new CustomEvent("whatsapp:inbound", { detail: { at: this.atValue } })
    )
  }
}
