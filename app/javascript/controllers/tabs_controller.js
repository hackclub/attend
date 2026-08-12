import { Controller } from "@hotwired/stimulus"

// Simple accessible tabs. Markup:
//   <div data-controller="tabs">
//     <div role="tablist">
//       <button data-tabs-target="tab" data-action="click->tabs#select keydown->tabs#keydown">...</button>
//     </div>
//     <div data-tabs-target="panel">...</div>
//   </div>
export default class extends Controller {
  static targets = ["tab", "panel"]
  static classes = ["active", "inactive"]

  connect() {
    this.select({ currentTarget: this.tabTargets[0] })
  }

  select(event) {
    const selected = event.currentTarget
    this.tabTargets.forEach((tab, index) => {
      const isActive = tab === selected
      tab.setAttribute("aria-selected", isActive ? "true" : "false")
      tab.setAttribute("tabindex", isActive ? "0" : "-1")
      this.activeClasses.forEach((c) => tab.classList.toggle(c, isActive))
      this.inactiveClasses.forEach((c) => tab.classList.toggle(c, !isActive))
      this.panelTargets[index]?.classList.toggle("hidden", !isActive)
    })
  }

  keydown(event) {
    const keys = { ArrowRight: 1, ArrowLeft: -1 }
    const step = keys[event.key]
    if (!step) return
    event.preventDefault()
    const current = this.tabTargets.indexOf(event.currentTarget)
    const next = (current + step + this.tabTargets.length) % this.tabTargets.length
    const nextTab = this.tabTargets[next]
    nextTab.focus()
    this.select({ currentTarget: nextTab })
  }
}
