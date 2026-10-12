import { Controller } from "@hotwired/stimulus"

// Collapses the admin console's side navigation to a slim rail, the way
// Cloudscape's app layout does, and remembers the choice per browser.
const STORAGE_KEY = "attend-console-nav"
const COLLAPSED_CLASS = "cs-nav-collapsed"

export default class extends Controller {
  static targets = ["toggle", "label"]

  connect() {
    this.sync()
  }

  toggle() {
    const collapsed = document.documentElement.classList.toggle(COLLAPSED_CLASS)
    try {
      if (collapsed) localStorage.setItem(STORAGE_KEY, "collapsed")
      else localStorage.removeItem(STORAGE_KEY)
    } catch (e) {
      // Private windows can refuse storage; the toggle still works for this page.
    }
    this.sync()
  }

  sync() {
    const collapsed = document.documentElement.classList.contains(COLLAPSED_CLASS)
    const label = collapsed ? "Show navigation" : "Hide navigation"
    this.toggleTarget.setAttribute("aria-expanded", String(!collapsed))
    this.toggleTarget.title = label
    this.labelTarget.textContent = label
  }
}
