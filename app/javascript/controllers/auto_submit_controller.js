import { Controller } from "@hotwired/stimulus"
import { dropBlankFields } from "utils/drop_blank_fields"

// Submits the form as soon as a filter changes, so there's no Filter button
// to press. Text input is debounced so each keystroke isn't a request.
//   <form data-controller="auto-submit">
//     <select data-action="change->auto-submit#submit">
// or, for every control at once, debounced:
//   <form data-controller="auto-submit" data-action="change->auto-submit#debouncedSubmit">
//
// The participant list morphs on these submits (turbo_refreshes_with :morph),
// so the form, its controls and this controller stay in place: focus, caret
// and anything typed while results load all carry over.
export default class extends Controller {
  static targets = ["search"]
  static values = { delay: { type: Number, default: 300 } }

  // Back restores a cached copy of the page with the controls as they were
  // left, which can be a filter that never ran. Show what the results were
  // filtered by instead.
  connect() {
    this.element.reset()
    this.submitted()
  }

  disconnect() {
    this.cancel()
  }

  // A link, another form or Back/Forward drops a search that hasn't been
  // sent yet, so it can't abort what the user just started.
  cancel() {
    clearTimeout(this.debounceTimer)
    this.debounceTimer = null
  }

  // Keep what's being typed when results for an earlier search arrive. The
  // field's default still follows the results, which is what connect()
  // resets to on Back.
  keepTypedSearch({ detail: { newElement } }) {
    if (document.activeElement !== this.searchTarget && !this.debounceTimer) return

    const results = newElement.defaultValue
    this.searchTarget.defaultValue = results
    // A blank search renders no value attribute, which makes the morph clear the field.
    newElement.defaultValue = results
    newElement.value = this.searchTarget.value
  }

  // Leave empty filters out of the URL.
  dropBlank({ formData }) {
    dropBlankFields(formData)
  }

  // Remember what the results are (or are about to be) filtered by, however
  // the form went out: a debounced change, Enter, or the no-JS button.
  submitted() {
    this.submittedQuery = this.query()
  }

  submit() {
    this.element.requestSubmit()
  }

  // Selects go through here too: arrowing through a closed select fires
  // change on every option in Windows browsers and Firefox.
  debouncedSubmit(event) {
    this.cancel()
    // Wait for IME and dead-key input to be committed before searching.
    if (event.isComposing) return

    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = null
      // Compare with the last submit, not the URL: the URL lags while results
      // load and can list the same filters in another order.
      if (this.query() !== this.submittedQuery) this.element.requestSubmit()
    }, this.delayValue)
  }

  query() {
    const params = new URLSearchParams(new FormData(this.element)).toString()
    return params ? `?${params}` : ""
  }
}
