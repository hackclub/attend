import { Controller } from "@hotwired/stimulus"
import { directUpload } from "utils/direct_upload"

// Uploads a headshot as soon as it's picked, so it's already stored by the
// time the participant presses Save & Continue. The server only stages it: its
// signed id goes into a hidden field, and the photo replaces the current
// headshot when the form is submitted. If the upload can't reach the server,
// the file stays in the input and goes up with the form as before.
//
// The bytes go straight to storage first (utils/direct_upload), and the server
// is sent only the stored blob's signed id to check and stage. When that
// direct upload fails, the file is posted to the server instead, the way it
// was before direct uploads.
export default class extends Controller {
  static targets = ["input", "staged", "preview", "image", "caption", "status"]
  static values = { url: String, directUploadUrl: String }

  connect() {
    this.request = 0
    this.initial = {
      staged: this.stagedTarget.value,
      required: this.inputTarget.required,
      src: this.imageTarget.getAttribute("src"),
      caption: this.captionTarget.textContent,
      hidden: this.previewTarget.hidden
    }
  }

  async upload() {
    const file = this.inputTarget.files[0]
    if (!file) return

    // A new pick replaces anything staged before it. Each pick is numbered so
    // a slow response to an earlier one can't overwrite a later one.
    const request = ++this.request
    this.stagedTarget.value = ""
    this.showPreview(file, request)
    this.setStatus("Uploading photo…")

    const signedBlobId = await directUpload(file, this.directUploadUrlValue)
    if (request !== this.request) return

    const formData = new FormData()
    if (signedBlobId) {
      formData.append("signed_blob_id", signedBlobId)
    } else {
      formData.append("headshot", file)
    }

    return fetch(this.urlValue, {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
      },
      body: formData
    })
      .then(async (response) => ({ response, data: await response.json() }))
      .then(({ response, data }) => {
        if (request !== this.request) return

        if (response.ok && data.success) {
          this.staged(data.signed_id)
        } else {
          this.rejected(data.error)
        }
      })
      .catch(() => {
        if (request !== this.request) return

        this.setStatus("Couldn't upload it yet. It will upload when you press Save & Continue.")
      })
  }

  staged(signedId) {
    this.stagedTarget.value = signedId
    // The photo is already on the server, so the form doesn't send it again.
    this.inputTarget.value = ""
    this.inputTarget.required = false
    this.setStatus("Uploaded. It's saved as your headshot when you press Save & Continue.")
    this.notifyAutosave()
  }

  // The server refused the photo (wrong type, too big, unreadable): put the
  // field back as it was when the page loaded.
  rejected(error) {
    this.inputTarget.value = ""
    this.inputTarget.required = this.initial.required
    this.stagedTarget.value = this.initial.staged
    this.restorePreview()
    this.setStatus(error || "That photo couldn't be uploaded. Please choose another.", true)
    this.notifyAutosave()
  }

  showPreview(file, request) {
    const reader = new FileReader()
    reader.onload = (event) => {
      if (request !== this.request) return

      this.imageTarget.src = event.target.result
      this.captionTarget.textContent = "New headshot"
      this.previewTarget.hidden = false
    }
    reader.readAsDataURL(file)
  }

  restorePreview() {
    if (this.initial.src) {
      this.imageTarget.src = this.initial.src
    } else {
      this.imageTarget.removeAttribute("src")
    }
    this.captionTarget.textContent = this.initial.caption
    this.previewTarget.hidden = this.initial.hidden
  }

  // Lets the form's autosave controller re-describe what's still pending.
  notifyAutosave() {
    this.element.dispatchEvent(new Event("change", { bubbles: true }))
  }

  setStatus(text, isError = false) {
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("text-(--danger-strong)", isError)
  }
}
