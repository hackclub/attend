import { Controller } from "@hotwired/stimulus"

// Collapses the admin console's side navigation to a slim rail, the way
// Cloudscape's app layout does, and remembers the choice per browser.
// Collapsed, each icon gets a tooltip naming its link. The tooltip is fixed
// to the viewport because the rail's scroll container would clip it.
const STORAGE_KEY = "attend-console-nav"
const COLLAPSED_CLASS = "cs-nav-collapsed"

export default class extends Controller {
  static targets = ["toggle", "label"]

  connect() {
    this.showTooltip = this.showTooltip.bind(this)
    this.hideTooltip = this.hideTooltip.bind(this)
    this.element.addEventListener("mouseover", this.showTooltip)
    this.element.addEventListener("focusin", this.showTooltip)
    this.element.addEventListener("mouseout", this.hideTooltip)
    this.element.addEventListener("focusout", this.hideTooltip)
    this.element.addEventListener("scroll", this.hideTooltip, true)
    this.sync()
  }

  disconnect() {
    this.element.removeEventListener("mouseover", this.showTooltip)
    this.element.removeEventListener("focusin", this.showTooltip)
    this.element.removeEventListener("mouseout", this.hideTooltip)
    this.element.removeEventListener("focusout", this.hideTooltip)
    this.element.removeEventListener("scroll", this.hideTooltip, true)
    this.hideTooltip()
  }

  toggle() {
    const collapsed = document.documentElement.classList.toggle(COLLAPSED_CLASS)
    try {
      if (collapsed) localStorage.setItem(STORAGE_KEY, "collapsed")
      else localStorage.removeItem(STORAGE_KEY)
    } catch (e) {
      // Private windows can refuse storage; the toggle still works for this page.
    }
    this.hideTooltip()
    this.sync()
  }

  sync() {
    const collapsed = this.collapsed
    const label = collapsed ? "Show navigation" : "Hide navigation"
    this.toggleTarget.setAttribute("aria-expanded", String(!collapsed))
    this.toggleTarget.title = label
    this.labelTarget.textContent = label
  }

  showTooltip(event) {
    const link = event.target.closest(".cs-sidenav-link")
    if (!link || !this.collapsed || !window.matchMedia("(min-width: 1024px)").matches) return
    if (link === this.tooltipFor) return

    this.hideTooltip()
    const rect = link.getBoundingClientRect()
    this.tooltip = document.createElement("div")
    this.tooltip.className = "cs-sidenav-tooltip"
    this.tooltip.setAttribute("aria-hidden", "true")
    this.tooltip.textContent = link.querySelector(".cs-sidenav-label")?.textContent ?? ""
    this.tooltip.style.left = `${rect.right + 8}px`
    this.tooltip.style.top = `${rect.top + rect.height / 2}px`
    document.body.appendChild(this.tooltip)
    this.tooltipFor = link
  }

  hideTooltip(event) {
    // Moving between an icon and its own label doesn't leave the link.
    if (event?.type === "mouseout" && this.tooltipFor?.contains(event.relatedTarget)) return
    this.tooltip?.remove()
    this.tooltip = null
    this.tooltipFor = null
  }

  get collapsed() {
    return document.documentElement.classList.contains(COLLAPSED_CLASS)
  }
}
