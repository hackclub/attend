import { Controller } from "@hotwired/stimulus"

const TOGGLE_SELECTOR = "[data-action*='dropdown#toggle']"
// Announced on document when a menu opens, so any other open menu closes.
// toggle() stops the click from propagating, which means the other menu's
// outside-click listener never hears it; this event fills that gap.
const OPEN_EVENT = "dropdown:open"

export default class extends Controller {
  static targets = ["menu"]

  connect() {
    // The previous version bound `hide` twice — once on connect and once on
    // disconnect — so removeEventListener never matched and the listener
    // outlived every Turbo navigation.
    this.hideHandler = this.hide.bind(this)
    this.keydownHandler = this.closeOnEscape.bind(this)
    this.otherOpenedHandler = (event) => { if (event.detail !== this) this.close() }
    document.addEventListener("click", this.hideHandler)
    document.addEventListener("keydown", this.keydownHandler)
    document.addEventListener(OPEN_EVENT, this.otherOpenedHandler)
    this.syncExpanded()
  }

  disconnect() {
    document.removeEventListener("click", this.hideHandler)
    document.removeEventListener("keydown", this.keydownHandler)
    document.removeEventListener(OPEN_EVENT, this.otherOpenedHandler)
  }

  toggle(event) {
    event.stopPropagation()
    const opening = this.isClosed
    this.menuTarget.classList.toggle("hidden")
    this.syncExpanded()
    if (opening) document.dispatchEvent(new CustomEvent(OPEN_EVENT, { detail: this }))
  }

  hide(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  closeOnEscape(event) {
    if (event.key !== "Escape" || this.isClosed) return
    this.close()
    // Escape has to hand focus back to the control that opened the menu,
    // otherwise keyboard users land at the top of the document.
    this.element.querySelector(TOGGLE_SELECTOR)?.focus()
  }

  close() {
    if (!this.hasMenuTarget) return

    this.menuTarget.classList.add("hidden")
    this.syncExpanded()
  }

  get isClosed() {
    return !this.hasMenuTarget || this.menuTarget.classList.contains("hidden")
  }

  syncExpanded() {
    const expanded = String(!this.isClosed)
    this.element
      .querySelectorAll(TOGGLE_SELECTOR)
      .forEach((toggle) => toggle.setAttribute("aria-expanded", expanded))
  }
}
