import { Controller } from "@hotwired/stimulus"
import { directUpload } from "utils/direct_upload"

// Sends a picked file straight to storage while the rest of the form is
// filled in, so saving the form doesn't wait on the bucket. Once stored, the
// blob's signed id goes in a hidden field and the file input loses its name,
// so the form sends the id instead of the file (the picked file stays shown).
//
// Anything short of a finished upload leaves the input alone, and the file is
// posted with the form the way it always was. That covers no JavaScript, a
// direct upload that fails (storage CORS not set up, a network error), and a
// form submitted before the upload finished.
export default class extends Controller {
  static targets = ["input", "signedId", "status"]
  static values = { url: String }

  connect() {
    this.request = 0
    this.inputName = this.inputTarget.name
  }

  async upload() {
    const request = ++this.request
    // A new pick replaces anything uploaded before it.
    this.inputTarget.name = this.inputName
    this.signedIdTarget.value = ""

    const file = this.inputTarget.files[0]
    if (!file) return this.setStatus("")

    this.setStatus("Uploading photo…")
    const signedId = await directUpload(file, this.urlValue)
    if (request !== this.request) return

    if (signedId) {
      this.signedIdTarget.value = signedId
      this.inputTarget.removeAttribute("name")
      this.setStatus("Uploaded. Save to use it.")
    } else {
      this.setStatus("")
    }
  }

  setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
