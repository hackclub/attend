import { Controller } from "@hotwired/stimulus"

// What each placeholder becomes, shown in the {{ picker. Keep in step with
// Message#personalize.
const MERGE_TAG_DESCRIPTIONS = {
  first_name: 'Recipient\'s first name, or "there"',
  event_name: 'This event\'s name',
  participant_first_name: 'Guardians only: their children\'s names'
}

export default class extends Controller {
  static targets = ["editor"]
  static values = {
    slackMode: { type: Boolean, default: false },
    // Where pasted, dropped or picked images are uploaded. Images are only
    // offered when it's set.
    imageUploadUrl: String,
    // Personalization tokens the server fills in, e.g. ["first_name"]. When
    // set, {{tokens}} in the editor are highlighted so staff can see they'll
    // be replaced; ones not in the list are marked as mistakes.
    placeholders: Array
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
    if (this.mergeTagFrame) cancelAnimationFrame(this.mergeTagFrame)
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
      // Wrap onto a second row on narrow screens rather than hiding buttons
      // behind a "more" menu.
      toolbar_mode: 'wrap',
      ...this.themeOptions(),
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

        if (this.placeholdersValue.length > 0) {
          editor.on('init SetContent input keyup change undo redo NodeChange', () => this.scheduleMergeTagHighlight())
          this.addMergeTagAutocompleter(editor)
        }
      }
    })
  }

  // Inside the admin console the editor follows the console's light or dark
  // mode and paints its editing area from the --cs-* tokens; elsewhere it
  // keeps TinyMCE's light look. Read once at init, so a mode switch shows on
  // the next page load.
  themeOptions() {
    const root = document.documentElement
    const inConsole = root.classList.contains('cs-console')
    const dark = inConsole && root.dataset.theme === 'dark'
    const token = (name, fallback) => (inConsole && getComputedStyle(root).getPropertyValue(name).trim()) || fallback

    const info = token('--cs-info', '#1d4ed8')
    const error = token('--cs-error', '#b91c1c')
    const style = `
      body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
        font-size: 14px; line-height: 1.5;
        background-color: ${token('--cs-bg-input', '#ffffff')};
        color: ${token('--cs-text-body', '#0f141a')};
      }
      a { color: ${token('--cs-accent', '#c8283f')}; }
      img { max-width: 100%; height: auto; }
      ::selection { background-color: ${token('--cs-bg-pressed', '#ffe5e9')}; }
      ::highlight(merge-tag) { background-color: color-mix(in srgb, ${info} 16%, transparent); color: ${info}; }
      ::highlight(merge-tag-unknown) { background-color: color-mix(in srgb, ${error} 14%, transparent); color: ${error}; text-decoration: underline wavy ${error}; }
    `

    return {
      skin: dark ? 'oxide-dark' : 'oxide',
      content_css: dark ? 'dark' : 'default',
      content_style: style
    }
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

  // Typing {{ opens a picker of the placeholders; keep typing to filter.
  // Choosing one replaces what was typed with the whole {{token}}.
  addMergeTagAutocompleter(editor) {
    editor.ui.registry.addAutocompleter('merge-tags', {
      trigger: '{{',
      minChars: 0,
      columns: 1,
      fetch: (pattern) => {
        const query = pattern.trim().toLowerCase()
        return Promise.resolve(
          this.placeholdersValue
            .filter((token) => token.includes(query))
            .map((token) => ({
              type: 'cardmenuitem',
              value: `{{${token}}}`,
              label: token,
              items: [
                {
                  type: 'cardcontainer',
                  direction: 'vertical',
                  items: [
                    { type: 'cardtext', text: `{{${token}}}`, name: 'token' },
                    { type: 'cardtext', text: MERGE_TAG_DESCRIPTIONS[token] || '' }
                  ]
                }
              ]
            }))
        )
      },
      onAction: (api, range, value) => {
        editor.selection.setRng(range)
        editor.insertContent(value)
        api.hide()
      }
    })
  }

  scheduleMergeTagHighlight() {
    if (this.mergeTagFrame) return
    this.mergeTagFrame = requestAnimationFrame(() => {
      this.mergeTagFrame = null
      this.highlightMergeTags()
    })
  }

  // Marks {{tokens}} with the CSS Custom Highlight API, which styles text
  // ranges without touching the DOM, so the saved HTML, the caret and undo
  // history are exactly as if nothing were highlighted. Matching runs one
  // text node at a time with the same pattern as Message::PLACEHOLDER_PATTERN
  // on the HTML: a token split by formatting or a line break isn't filled in
  // when sent, so it isn't highlighted either. Browsers without the API just
  // show plain text.
  highlightMergeTags() {
    const win = this.editor?.getWin()
    const doc = this.editor?.getDoc()
    if (!win?.CSS?.highlights || !win.Highlight || !doc?.body) return

    const known = new Set(this.placeholdersValue)
    const knownRanges = []
    const unknownRanges = []
    const pattern = /\{\{[ \t\r\n]*(\w+)[ \t\r\n]*\}\}/g
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT)

    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      for (const match of node.data.matchAll(pattern)) {
        const range = doc.createRange()
        range.setStart(node, match.index)
        range.setEnd(node, match.index + match[0].length)
        ;(known.has(match[1]) ? knownRanges : unknownRanges).push(range)
      }
    }

    win.CSS.highlights.set('merge-tag', new win.Highlight(...knownRanges))
    win.CSS.highlights.set('merge-tag-unknown', new win.Highlight(...unknownRanges))
  }

  getContent() {
    return this.editor ? this.editor.getContent() : this.editorTarget.value
  }
}
