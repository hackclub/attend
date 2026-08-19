import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"
import { html } from "utils/html"

export default class extends Controller {
  static values = { importBatchId: String }
  static targets = [
    "statusMessage",
    "percentage",
    "progressBar",
    "totalCount",
    "importedCount",
    "skippedCount",
    "errorCount",
    "invitesSentCount",
    "errorsSection",
    "errorsList"
  ]

  connect() {
    this.subscription = consumer.subscriptions.create(
      { channel: "ImportBatchChannel", import_batch_id: this.importBatchIdValue },
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
    if (this.hasStatusMessageTarget) {
      this.statusMessageTarget.textContent = data.status_message
    }

    if (this.hasPercentageTarget) {
      this.percentageTarget.textContent = `${data.progress_percentage}%`
    }

    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = `${data.progress_percentage}%`
      
      if (data.status === "completed") {
        this.progressBarTarget.style.backgroundColor = "#16a34a"
      } else if (data.status === "failed") {
        this.progressBarTarget.style.backgroundColor = "#dc2626"
      } else {
        this.progressBarTarget.style.backgroundColor = "#2563eb"
      }
    }

    if (this.hasTotalCountTarget) {
      this.totalCountTarget.textContent = data.total_count
    }

    if (this.hasImportedCountTarget) {
      this.importedCountTarget.textContent = data.imported_count
    }

    if (this.hasSkippedCountTarget) {
      this.skippedCountTarget.textContent = data.skipped_count
    }

    if (this.hasErrorCountTarget) {
      this.errorCountTarget.textContent = data.error_count
    }

    if (this.hasInvitesSentCountTarget) {
      this.invitesSentCountTarget.textContent = data.invites_sent_count
    }

    if (data.errors && data.errors.length > 0 && this.hasErrorsSectionTarget) {
      this.errorsSectionTarget.style.display = ""
      
      if (this.hasErrorsListTarget) {
        this.errorsListTarget.innerHTML = data.errors.map(error => {
          if (error.row) {
            const emailPart = error.email ? ` (${error.email})` : ""
            return html`<li>Row ${error.row}${emailPart}: ${error.error}</li>`
          } else {
            return html`<li>${error.email}: ${error.error}</li>`
          }
        }).join("")
      }
    }

    if (data.completed) {
      window.location.reload()
    }
  }
}
