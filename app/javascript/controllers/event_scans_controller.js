import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static values = { eventId: String }
  static targets = ["scans", "count", "empty"]

  connect() {
    this.subscription = consumer.subscriptions.create(
      { channel: "EventScansChannel", event_id: this.eventIdValue },
      {
        received: (data) => this.handleScan(data)
      }
    )
  }

  disconnect() {
    if (this.subscription) {
      this.subscription.unsubscribe()
    }
  }

  handleScan(data) {
    if (this.hasEmptyTarget) {
      this.emptyTarget.remove()
    }

    const scanHtml = `
      <div class="flex items-center justify-between border-b border-gray-100 pb-3 bg-green-50 -mx-2 px-2 rounded transition-colors" data-scan-id="${data.scan_id}">
        <div>
          <p class="font-medium text-sm">${data.participant.display_name}</p>
          <p class="text-xs text-gray-500">just now</p>
        </div>
        <span class="text-xs text-gray-500">${data.scanned_by}</span>
      </div>
    `

    this.scansTarget.insertAdjacentHTML("afterbegin", scanHtml)

    setTimeout(() => {
      const newScan = this.scansTarget.querySelector(`[data-scan-id="${data.scan_id}"]`)
      if (newScan) newScan.classList.remove("bg-green-50")
    }, 2000)

    if (this.hasCountTarget) {
      this.countTarget.textContent = parseInt(this.countTarget.textContent) + 1
    }
  }
}
