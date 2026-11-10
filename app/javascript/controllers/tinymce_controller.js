import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["editor"]
  static values = {
    slackMode: { type: Boolean, default: false },
    // Where pasted, dropped or picked images are uploaded. Images are only
    // offered when it's set.
    imageUploadUrl: String
  }

  async connect() {
    this.pendingUploads = 0
    this.boundHoldSubmit = this.holdSubmitForUploads.bind(this)
    // Capture on the document so this runs before TinyMCE copies the content
    // back into the textarea, and before Turbo or autosave see the submit.
    document.addEventListener("submit", this.boundHoldSubmit, true)

    await this.loadTinymce()
    // Bail if turbo navigated away while the script was still downloading
    if (!this.element.isConnected) return
    this.initEditor()
  }

  disconnect() {
    document.removeEventListener("submit", this.boundHoldSubmit, true)
    if (this.editor) {
      this.editor.destroy()
      this.editor = null
    }
  }

  // Loads TinyMCE on demand — it's a large bundle only two admin forms use,
  // so it must not ship in the layout head of every admin page.
  // referrerpolicy="origin" is required by TinyMCE's GPL license check.
  async loadTinymce() {
    if (typeof tinymce !== "undefined") return

    window._tinymceLoadPromise ||= new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = "https://cdn.jsdelivr.net/npm/tinymce@7/tinymce.min.js"
      script.referrerPolicy = "origin"
      script.onload = resolve
      script.onerror = reject
      document.head.appendChild(script)
    })

    return window._tinymceLoadPromise
  }

  initEditor() {
    if (typeof tinymce === "undefined") return

    const target = this.editorTarget
    const isSlackMode = this.slackModeValue
    const allowImages = !isSlackMode && this.hasImageUploadUrlValue && this.imageUploadUrlValue.length > 0
    
    const toolbar = isSlackMode 
      ? 'bold italic strikethrough | link | bullist numlist | blockquote code'
      : `bold italic underline strikethrough | link${allowImages ? ' image' : ''} | bullist numlist | blockquote code | removeformat`

    const imageOptions = allowImages ? {
      images_upload_handler: (blobInfo) => this.uploadImage(blobInfo),
      images_file_types: 'jpeg,jpg,png,gif,webp',
      file_picker_types: 'image',
      image_dimensions: false,
      // Keep the upload's address exactly as the server gave it, which is
      // what the server recognises when the body is saved.
      convert_urls: false
    } : {}

    tinymce.init({
      target: target,
      license_key: 'gpl',
      height: 300,
      menubar: false,
      statusbar: false,
      plugins: allowImages ? 'link lists autolink image' : 'link lists autolink',
      toolbar: toolbar,
      content_style: 'body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; font-size: 14px; line-height: 1.5; } img { max-width: 100%; height: auto; }',
      link_default_target: '_blank',
      link_title: false,
      link_context_toolbar: true,
      valid_elements: 'p,br,strong,b,em,i,u,s,strike,a[href|target],ul,ol,li,blockquote,code,pre' + (allowImages ? ',img[src|alt]' : ''),
      ...imageOptions,
      formats: {
        bold: { inline: 'strong' },
        italic: { inline: 'em' },
        underline: { inline: 'u' },
        strikethrough: { inline: 's' }
      },
      setup: (editor) => {
        this.editor = editor
        
        editor.on('change keyup', () => this.sync('input'))
        editor.on('blur', () => this.sync('change'))
      }
    })
  }

  // Copies the editor into the textarea and tells autosave. Not while an image
  // is uploading: until the upload finishes the editor shows it from a
  // temporary blob: address, and a draft saved with that would lose the
  // picture. The textarea keeps the last good content meanwhile, and
  // uploadImage syncs once the real address is in.
  sync(eventName = 'input') {
    if (!this.editor || this.pendingUploads > 0 || this.hasPendingImages()) return

    this.editor.save()
    this.editorTarget.dispatchEvent(new Event(eventName, { bubbles: true }))
  }

  // TinyMCE shows a pasted, dropped or picked image from a blob: address
  // until its upload finishes and the server's address replaces it.
  hasPendingImages() {
    return Array.from(this.editor.getBody().querySelectorAll('img'))
      .some((img) => /^blob:/i.test(img.getAttribute('src') || ''))
  }

  // Sending (or saving) while an image is still uploading would go out without
  // it, so wait for the uploads, then submit again with the same button.
  async holdSubmitForUploads(event) {
    const form = event.target
    if (!this.editor || form !== this.editorTarget.form) return
    // The resubmit below goes through: whatever is left, the server rejects
    // rather than this looping.
    if (this.resubmitting) {
      this.resubmitting = false
      return
    }
    if (this.pendingUploads === 0 && !this.hasPendingImages()) return

    event.preventDefault()
    event.stopImmediatePropagation()
    if (this.waitingToSubmit) return
    this.waitingToSubmit = true

    try {
      await this.editor.uploadImages()
      await this.whenUploadsSettle()
    } finally {
      this.waitingToSubmit = false
    }
    // An image whose upload failed was removed and staff were told.
    this.editor.save()
    this.resubmitting = true
    form.requestSubmit(event.submitter)
  }

  whenUploadsSettle() {
    if (this.pendingUploads === 0) return Promise.resolve()
    return new Promise((resolve) => { this.uploadsSettled = resolve })
  }

  async uploadImage(blobInfo) {
    this.pendingUploads += 1
    try {
      return await this.postImage(blobInfo)
    } finally {
      this.pendingUploads -= 1
      if (this.pendingUploads === 0) {
        // TinyMCE swaps in the returned address (or removes a failed image)
        // after this promise settles, so sync on the next tick.
        setTimeout(() => {
          this.sync('input')
          this.uploadsSettled?.()
          this.uploadsSettled = null
        }, 0)
      }
    }
  }

  async postImage(blobInfo) {
    const formData = new FormData()
    formData.append('file', blobInfo.blob(), blobInfo.filename())

    let response
    try {
      response = await fetch(this.imageUploadUrlValue, {
        method: 'POST',
        body: formData,
        headers: {
          'Accept': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
        }
      })
    } catch {
      throw { message: 'The image could not be uploaded. Check your connection and try again.', remove: true }
    }

    const data = await response.json().catch(() => ({}))
    if (!response.ok || !data.location) {
      throw { message: data.error || 'The image could not be uploaded.', remove: true }
    }
    return data.location
  }

  getContent() {
    return this.editor ? this.editor.getContent() : this.editorTarget.value
  }
}
