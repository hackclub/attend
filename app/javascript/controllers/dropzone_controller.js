import { Controller } from "@hotwired/stimulus"

// Excel saves "Unicode Text" and tab-delimited exports as .txt, and the import
// reads those too, so the dropzone can't be .csv-only.
const ACCEPTED_EXTENSIONS = ['.csv', '.txt']

export default class extends Controller {
  static targets = ["input", "content", "selected", "fileName", "submit", "zone"]

  openFilePicker(e) {
    // Don't trigger if clicking on the file input itself
    if (e.target !== this.inputTarget) {
      this.inputTarget.click()
    }
  }

  handleDragOver(e) {
    e.preventDefault()
    this.zoneTarget.classList.add('border-blue-500', 'bg-blue-50')
  }

  handleDragLeave() {
    this.zoneTarget.classList.remove('border-blue-500', 'bg-blue-50')
  }

  handleDrop(e) {
    e.preventDefault()
    this.zoneTarget.classList.remove('border-blue-500', 'bg-blue-50')
    
    const files = e.dataTransfer.files
    if (files.length > 0 && this.isAccepted(files[0].name)) {
      this.inputTarget.files = files
      this.showFileSelected(files[0].name)
    }
  }

  isAccepted(name) {
    const lowered = name.toLowerCase()
    return ACCEPTED_EXTENSIONS.some((extension) => lowered.endsWith(extension))
  }

  fileSelected(e) {
    if (e.target.files.length > 0) {
      this.showFileSelected(e.target.files[0].name)
    }
  }

  showFileSelected(name) {
    this.contentTarget.classList.add('hidden')
    this.selectedTarget.classList.remove('hidden')
    this.fileNameTarget.textContent = name
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = false
    }
  }
}
