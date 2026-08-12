import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Shows live progress of a background Slack channel sync
// (SyncSlackChannelJob broadcasts on SlackSyncChannel).
export default class extends Controller {
  static values = { eventId: String }
  static targets = ["banner", "message"]

  connect() {
    this.subscription = consumer.subscriptions.create(
      { channel: "SlackSyncChannel", event_id: this.eventIdValue },
      {
        received: (data) => this.handleProgress(data)
      }
    )
  }

  disconnect() {
    if (this.subscription) {
      this.subscription.unsubscribe()
    }
  }

  handleProgress(data) {
    if (this.hasBannerTarget) {
      this.bannerTarget.classList.remove("hidden")
    }
    if (!this.hasMessageTarget) return

    if (data.status === "completed") {
      const parts = []
      if (data.added > 0) parts.push(`${data.added} invited`)
      if (data.already_member > 0) parts.push(`${data.already_member} already in channel`)
      if (data.failed > 0) parts.push(`${data.failed} failed`)
      if (data.emailed > 0) parts.push(`${data.emailed} emailed`)
      this.messageTarget.textContent =
        `Slack sync complete${parts.length ? ": " + parts.join(", ") : " — no participants with linked Slack accounts"}`
    } else {
      this.messageTarget.textContent =
        `Syncing Slack channel… ${data.processed}/${data.total} (${data.added} invited, ${data.failed} failed)`
    }
  }
}
