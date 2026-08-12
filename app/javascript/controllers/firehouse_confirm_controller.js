import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  confirm(event) {
    const checkbox = this.element.querySelector("input[name='sync_to_slack']")
    if (!checkbox?.checked) return

    const category = this.element.querySelector("select[name='incident[category]']")?.value
    if (category === "behavior") return

    const label = category ? category.replace(/_/g, " ") : "this"
    if (!window.confirm(`You're about to sync a ${label} report to the HQ Firehouse Slack channel. Are you sure?`)) {
      event.preventDefault()
    }
  }
}
