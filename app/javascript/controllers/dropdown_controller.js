import { Controller } from "@hotwired/stimulus"

const TOGGLE_SELECTOR = "[data-action*='dropdown#toggle']"

export default class extends Controller {
  static targets = ["menu"]

  connect() {
    // The previous version bound `hide` twice — once on connect and once on
    // disconnect — so removeEventListener never matched and the listener
    // outlived every Turbo navigation.
    this.hideHandler = this.hide.bind(this)
    this.keydownHandler = this.closeOnEscape.bind(this)
    document.addEventListener("click", this.hideHandler)
    document.addEventListener("keydown", this.keydownHandler)
    this.syncExpanded()
  }

  disconnect() {
    document.removeEventListener("click", this.hideHandler)
    document.removeEventListener("keydown", this.keydownHandler)
  }

  toggle(event) {
    event.stopPropagation()
    this.menuTarget.classList.toggle("hidden")
    this.syncExpanded()
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
