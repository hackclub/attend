import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["search", "list", "count", "plural", "checkbox"]

  filter() {
    const query = this.searchTarget.value.toLowerCase()
    this.listTarget.querySelectorAll("[data-name]").forEach(row => {
      const name = row.dataset.name
      row.classList.toggle("hidden", !name.includes(query))
    })
  }

  updateCount() {
    const count = this.checkboxTargets.filter(cb => cb.checked).length
    this.countTarget.textContent = count
    this.pluralTarget.textContent = count === 1 ? "" : "s"
  }

  clearAll(event) {
    event.preventDefault()
    this.checkboxTargets.forEach(cb => cb.checked = false)
    this.updateCount()
  }
}
