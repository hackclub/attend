import { Controller } from "@hotwired/stimulus"

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
    if (files.length > 0 && files[0].name.endsWith('.csv')) {
      this.inputTarget.files = files
      this.showFileSelected(files[0].name)
    }
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
