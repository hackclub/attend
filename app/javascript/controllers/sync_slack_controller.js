import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "slackCount", "emailCount", "lastSync", "loading", "content", "slackRow", "emailRow", "emailCheckbox"]
  static values = { previewUrl: String, formUrl: String }

  async open(event) {
    event.preventDefault()
    this.modalTarget.classList.remove("hidden")
    this.loadingTarget.classList.remove("hidden")
    this.contentTarget.classList.add("hidden")

    try {
      const response = await fetch(this.previewUrlValue, {
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
        }
      })

      if (!response.ok) {
        const data = await response.json()
        alert(data.error || "Failed to load preview")
        this.close()
        return
      }

      const data = await response.json()
      this.slackCountTarget.textContent = data.slack_invite_count
      this.emailCountTarget.textContent = data.email_count
      this.lastSyncTarget.textContent = data.last_sync

      if (data.slack_invite_count > 0) {
        this.slackRowTarget.classList.remove("hidden")
      } else {
        this.slackRowTarget.classList.add("hidden")
      }

      if (data.email_count > 0) {
        this.emailRowTarget.classList.remove("hidden")
      } else {
        this.emailRowTarget.classList.add("hidden")
      }

      this.loadingTarget.classList.add("hidden")
      this.contentTarget.classList.remove("hidden")
    } catch (error) {
      console.error("Error loading sync preview:", error)
      alert("Failed to load preview")
      this.close()
    }
  }

  close() {
    this.modalTarget.classList.add("hidden")
  }

  closeOnBackdrop(event) {
    if (event.target === this.modalTarget) {
      this.close()
    }
  }

  submit() {
    const form = document.createElement("form")
    form.method = "POST"
    form.action = this.formUrlValue

    const csrfToken = document.querySelector('meta[name="csrf-token"]').content
    const csrfInput = document.createElement("input")
    csrfInput.type = "hidden"
    csrfInput.name = "authenticity_token"
    csrfInput.value = csrfToken
    form.appendChild(csrfInput)

    const sendEmailsInput = document.createElement("input")
    sendEmailsInput.type = "hidden"
    sendEmailsInput.name = "send_emails"
    sendEmailsInput.value = this.hasEmailCheckboxTarget && this.emailCheckboxTarget.checked ? "1" : "0"
    form.appendChild(sendEmailsInput)

    document.body.appendChild(form)
    form.submit()
  }
}
