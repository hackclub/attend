import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["editor"]
  static values = {
    slackMode: { type: Boolean, default: false }
  }

  async connect() {
    await this.loadTinymce()
    // Bail if turbo navigated away while the script was still downloading
    if (!this.element.isConnected) return
    this.initEditor()
  }

  disconnect() {
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
    
    const toolbar = isSlackMode 
      ? 'bold italic strikethrough | link | bullist numlist | blockquote code'
      : 'bold italic underline strikethrough | link | bullist numlist | blockquote code | removeformat'

    tinymce.init({
      target: target,
      license_key: 'gpl',
      height: 300,
      menubar: false,
      statusbar: false,
      plugins: 'link lists autolink',
      toolbar: toolbar,
      content_style: 'body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; font-size: 14px; line-height: 1.5; }',
      link_default_target: '_blank',
      link_title: false,
      link_context_toolbar: true,
      valid_elements: 'p,br,strong,b,em,i,u,s,strike,a[href|target],ul,ol,li,blockquote,code,pre',
      formats: {
        bold: { inline: 'strong' },
        italic: { inline: 'em' },
        underline: { inline: 'u' },
        strikethrough: { inline: 's' }
      },
      setup: (editor) => {
        this.editor = editor
        
        editor.on('change keyup', () => {
          editor.save()
          target.dispatchEvent(new Event('input', { bubbles: true }))
        })
        
        editor.on('blur', () => {
          editor.save()
          target.dispatchEvent(new Event('change', { bubbles: true }))
        })
      }
    })
  }

  getContent() {
    return this.editor ? this.editor.getContent() : this.editorTarget.value
  }
}
