import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

export default class extends Controller {
  static targets = ["button", "progress", "progressBar", "progressText"]
  static values = { eventId: String }

  connect() {
    this.consumer = createConsumer()
    this.hasReloaded = false
    this.subscribeToChannel()
    this.checkInitialStatus()
  }

  disconnect() {
    if (this.subscription) {
      this.subscription.unsubscribe()
    }
    if (this.consumer) {
      this.consumer.disconnect()
    }
  }

  subscribeToChannel() {
    this.subscription = this.consumer.subscriptions.create(
      { channel: "AirportRefreshChannel", event_id: this.eventIdValue },
      {
        received: (data) => {
          this.handleUpdate(data)
        }
      }
    )
  }

  async checkInitialStatus() {
    try {
      const response = await fetch(`/admin/events/${this.eventIdValue}/airport_mode/refresh_status`)
      const data = await response.json()
      this.handleUpdate(data)
    } catch (error) {
      console.error("Failed to check refresh status:", error)
    }
  }

  handleUpdate(data) {
    if (data.status === "in_progress") {
      this.showProgress(data)
      this.wasInProgress = true
    } else if (data.status === "complete" && this.wasInProgress && !this.hasReloaded) {
      this.showComplete(data)
      this.hasReloaded = true
      setTimeout(() => {
        window.location.reload()
      }, 1000)
    } else {
      this.hideProgress()
    }
  }

  showProgress(data) {
    this.buttonTarget.classList.add("hidden")
    this.progressTarget.classList.remove("hidden")

    const percentage = data.total > 0 ? Math.round((data.completed / data.total) * 100) : 0
    this.progressBarTarget.style.width = `${percentage}%`
    this.progressTextTarget.textContent = data.message || `Refreshing... ${percentage}%`
  }

  showComplete(data) {
    if (this.hasProgressTarget) {
      this.progressTextTarget.textContent = data.message || "Complete!"
      this.progressBarTarget.style.width = "100%"
    }
  }

  hideProgress() {
    if (this.hasButtonTarget && this.hasProgressTarget) {
      this.buttonTarget.classList.remove("hidden")
      this.progressTarget.classList.add("hidden")
    }
  }
}
