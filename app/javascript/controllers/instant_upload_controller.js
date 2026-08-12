import { Controller } from "@hotwired/stimulus"

// Uploads a single image (logo or banner) as soon as it's selected, so admins
// don't have to submit the whole multipart form and wait out the upload on save.
// Falls back to normal form submission when there's no endpoint yet (e.g. a
// brand-new event that hasn't been created).
export default class extends Controller {
  static targets = ["input", "status"]
  static values = { url: String, field: String }

  upload() {
    const file = this.inputTarget.files[0]
    if (!file) return

    // No endpoint (event not persisted yet) → leave the file for normal submit.
    if (!this.hasUrlValue || this.urlValue.length === 0) return

    const formData = new FormData()
    formData.append("field", this.fieldValue)
    formData.append("file", file)

    this.setStatus("Uploading…")

    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
      },
      body: formData
    })
      .then(async (response) => {
        const data = await response.json().catch(() => ({}))
        if (response.ok && data.success) {
          this.replacePreview(data.preview_html)
          // Clear the input so the main "Save" doesn't re-upload the same file.
          this.inputTarget.value = ""
          this.setStatus("Saved ✓")
        } else {
          this.setStatus(data.error || "Upload failed", true)
        }
      })
      .catch(() => this.setStatus("Upload failed", true))
  }

  replacePreview(html) {
    if (!html) return
    const current = document.getElementById(`${this.fieldValue}_preview`)
    if (current) current.outerHTML = html
  }

  setStatus(text, isError = false) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("text-red-600", isError)
    this.statusTarget.classList.toggle("text-gray-400", !isError)
  }
}
