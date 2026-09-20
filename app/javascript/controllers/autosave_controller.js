import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    url: String,
    createUrl: String,
    notifyOnly: { type: Boolean, default: false }
  }

  connect() {
    this.timeout = null
    this.inFlight = false
    this.queued = false
    this.revision = 0
    this.savedRevision = 0
    this.submitting = false
    this.statusEl = this.element.querySelector('[data-autosave-target="status"]') || document.getElementById("save-status")
    this.retryEl = this.element.querySelector('[data-autosave-target="retry"]')
    this.boundBeforeUnload = this.beforeUnload.bind(this)
    this.boundBeforeVisit = this.beforeVisit.bind(this)
    this.boundSubmit = this.handleSubmit.bind(this)
    window.addEventListener("beforeunload", this.boundBeforeUnload)
    document.addEventListener("turbo:before-visit", this.boundBeforeVisit)
    this.element.addEventListener("submit", this.boundSubmit)
  }

  disconnect() {
    if (this.timeout) {
      clearTimeout(this.timeout)
    }
    window.removeEventListener("beforeunload", this.boundBeforeUnload)
    document.removeEventListener("turbo:before-visit", this.boundBeforeVisit)
    this.element.removeEventListener("submit", this.boundSubmit)
  }

  input(event) {
    this.changed(event)
  }

  change(event) {
    this.changed(event)
  }

  changed(event) {
    this.markChanged()

    if (event?.target?.type === "file") {
      this.updatePendingStatus()
      return
    }

    if (this.notifyOnlyValue) {
      this.updateStatus("You have unsaved changes. Use Save & Continue.")
      return
    }

    this.debouncedSave()
  }

  markChanged() {
    this.revision += 1
    this.setRetryVisible(false)
  }

  debouncedSave(event) {
    if (event) this.markChanged()
    if (!this.shouldSave()) return

    if (this.timeout) {
      clearTimeout(this.timeout)
    }

    this.updateSavingStatus()

    this.timeout = setTimeout(() => {
      this.save()
    }, 1000)
  }

  // A brand-new message has no update URL yet — don't create a draft record
  // until the user has actually written a subject or body.
  isPersisted() {
    return this.hasUrlValue && this.urlValue.length > 0
  }

  hasContent() {
    const form = this.element
    const subject = form.querySelector('[name="message[subject]"]')
    const body = form.querySelector('[name="message[body]"]')
    const subjectValue = subject ? subject.value.trim() : ""
    const bodyValue = body ? body.value.trim() : ""
    return subjectValue.length > 0 || bodyValue.length > 0
  }

  shouldSave() {
    return this.isPersisted() || this.hasContent()
  }

  save(event) {
    if (event) this.markChanged()
    if (this.timeout) {
      clearTimeout(this.timeout)
      this.timeout = null
    }

    if (!this.shouldSave()) return Promise.resolve()

    // Only one save on the wire at a time. On a slow connection two overlapping
    // PATCHes write the same rows concurrently and can deadlock each other, so
    // coalesce anything that happens mid-flight into a single follow-up save.
    if (this.inFlight) {
      this.queued = true
      return this.currentRequest
    }

    const requestRevision = this.revision
    const persisted = this.isPersisted()
    const form = this.element
    const formData = new FormData(form)
    formData.append('autosave', 'true')

    // File inputs only matter on a real submit — resending them on every
    // autosave re-uploads the whole file and churns Active Storage records.
    form.querySelectorAll('input[type="file"]').forEach((input) => {
      if (input.name) formData.delete(input.name)
    })

    // New flight legs remain in the live form for the explicit submit. Sending
    // them through autosave would make a retry after a lost response create a
    // duplicate, because the browser does not yet have a persisted leg ID.
    form.querySelectorAll("[data-autosave-skip]").forEach((container) => {
      if (!this.isNewFlightLeg(container)) return

      container.querySelectorAll("input, select, textarea").forEach((input) => {
        if (input.name) formData.delete(input.name)
      })
    })
    form.querySelectorAll("input[data-autosave-pending-deletion]").forEach((input) => {
      if (input.name) formData.delete(input.name)
    })

    // intl-tel-input keeps the country code out of the field itself, so the raw
    // value here is bare national digits. Autosave writes straight to the record,
    // so sending those means a non-US number is parsed against the default
    // country, fails validation and is silently dropped — while the status line
    // still says "Saved". Send the same E.164 number a real submit would.
    form.querySelectorAll('input[type="tel"]').forEach((input) => {
      if (!input.name || !input.iti) return

      const e164 = input.iti.getNumber()
      if (e164) formData.set(input.name, e164)
    })

    this.inFlight = true
    this.updateSavingStatus()

    this.currentRequest = fetch(persisted ? this.urlValue : this.createUrlValue, {
      method: persisted ? "PATCH" : "POST",
      headers: {
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
      },
      body: formData
    })
    .then(async response => ({ response, data: await response.json() }))
    .then(({ response, data }) => {
      if (data.success) {
        if (!persisted) {
          this.markPersisted(data)
        }
        this.savedRevision = Math.max(this.savedRevision, requestRevision)
        this.setRetryVisible(false)

        if (this.revision > requestRevision) {
          this.updateStatus("Saving newer changes...")
        } else {
          this.updateSavedStatus(data.saved_at)
        }
      } else {
        this.showFailure(data.errors)
      }
    })
    .catch(error => {
      console.error("Autosave error:", error)
      this.showFailure([ "Check your connection, then retry." ])
    })
    .finally(() => {
      this.inFlight = false
      if (this.queued) {
        this.queued = false
        this.save()
      }
    })

    return this.currentRequest
  }

  retry(event) {
    event?.preventDefault()
    this.setRetryVisible(false)
    return this.save()
  }

  handleSubmit(event) {
    if (this.timeout) {
      clearTimeout(this.timeout)
      this.timeout = null
    }

    if (this.submitting) return
    if (!this.inFlight) {
      this.submitting = true
      return
    }

    event.preventDefault()
    if (this.pendingSubmit) return

    this.updateStatus("Finishing the current save...")
    this.pendingSubmit = this.finishAutosaves().then(() => {
      this.submitting = true
      this.element.requestSubmit(event.submitter)
    })
  }

  async finishAutosaves() {
    while (this.inFlight) {
      await this.currentRequest
    }
  }

  beforeUnload(event) {
    if (this.submitting || !this.hasUnsavedChanges()) return

    event.preventDefault()
    event.returnValue = ""
  }

  beforeVisit(event) {
    if (this.submitting || !this.hasUnsavedChanges()) return
    if (window.confirm("You have unsaved changes. Leave this page anyway?")) return

    event.preventDefault()
  }

  hasUnsavedChanges() {
    return this.revision > this.savedRevision || this.inFlight || this.timeout !== null || this.explicitPendingReasons().length > 0
  }

  explicitPendingReasons() {
    const reasons = []
    const hasFile = Array.from(this.element.querySelectorAll('input[type="file"]'))
      .some((input) => input.files?.length > 0)
    const hasNewFlightLeg = Array.from(this.element.querySelectorAll("[data-autosave-skip]"))
      .some((container) => this.isNewFlightLeg(container) &&
        (container.dataset.autosaveNew === "true" || this.flightLegHasContent(container)))
    const hasRemovedFlightLeg = this.element.querySelectorAll("input[data-autosave-pending-deletion]").length > 0

    if (hasFile) reasons.push("photo or file")
    if (hasNewFlightLeg) reasons.push("new flight details")
    if (hasRemovedFlightLeg) reasons.push("removed flight details")
    return reasons
  }

  isNewFlightLeg(container) {
    const idInput = container.querySelector('input[name*="[id]"]')
    return !idInput?.value
  }

  flightLegHasContent(container) {
    return Array.from(container.querySelectorAll("input, select, textarea")).some((input) => {
      if (input.disabled || !input.name) return false
      if (input.name.endsWith("[id]") || input.name.endsWith("[position]") || input.name.includes("_time_zone]")) return false
      return input.value?.trim().length > 0
    })
  }

  updateSavingStatus() {
    const pending = this.explicitPendingReasons()
    const suffix = pending.length > 0 ? ` ${this.pendingMessage(pending)}` : ""
    this.updateStatus(`Saving text...${suffix}`)
  }

  updateSavedStatus(savedAt) {
    const pending = this.explicitPendingReasons()
    if (pending.length > 0) {
      this.updateStatus(`Text saved. ${this.pendingMessage(pending)}`)
      return
    }

    const time = new Date(savedAt)
    this.updateStatus(`Saved at ${time.toLocaleTimeString()}`)
  }

  updatePendingStatus() {
    const pending = this.explicitPendingReasons()
    this.updateStatus(this.pendingMessage(pending))
  }

  pendingMessage(reasons) {
    const description = reasons.join(" and ")
    return `${description.charAt(0).toUpperCase()}${description.slice(1)} must be uploaded with Save & Continue.`
  }

  showFailure(errors = []) {
    const detail = errors.filter(Boolean).join(" ") || "Please retry."
    this.updateStatus(`Not saved: ${detail}`, true)
    this.setRetryVisible(true)
  }

  setRetryVisible(visible) {
    if (this.retryEl) this.retryEl.hidden = !visible
  }

  // Once the draft has been created, switch the form from POST-create mode to
  // PATCH-update mode so further saves and the "Next: Preview" submit target it.
  markPersisted(data) {
    this.urlValue = data.update_url

    const form = this.element
    if (data.form_action) {
      form.setAttribute("action", data.form_action)
    }

    let methodInput = form.querySelector('input[name="_method"]')
    if (!methodInput) {
      methodInput = document.createElement("input")
      methodInput.type = "hidden"
      methodInput.name = "_method"
      form.appendChild(methodInput)
    }
    methodInput.value = "patch"

    if (data.edit_url) {
      window.history.replaceState(null, "", data.edit_url)
    }
  }

  toggleSchedule(event) {
    this.markChanged()
    const scheduleFields = document.getElementById("schedule-fields")
    const scheduledAtInput = document.querySelector('input[name="message[scheduled_at]"]')
    
    if (event.target.checked) {
      scheduleFields.classList.remove("hidden")
    } else {
      scheduleFields.classList.add("hidden")
      if (scheduledAtInput) {
        scheduledAtInput.value = ""
      }
      this.save()
    }
  }

  toggleParticipantSelect(event) {
    const container = document.getElementById("participant-select-container")
    if (container) {
      if (event.target.value === "specific_participants") {
        container.classList.remove("hidden")
      } else {
        container.classList.add("hidden")
      }
    }
  }

  filterParticipants(event) {
    const query = event.target.value.toLowerCase()
    const rows = document.querySelectorAll(".participant-row")
    
    rows.forEach(row => {
      const name = row.dataset.name || ""
      if (name.includes(query)) {
        row.classList.remove("hidden")
      } else {
        row.classList.add("hidden")
      }
    })
  }

  updateSelectedCount() {
    const checkboxes = document.querySelectorAll(".participant-checkbox:checked")
    const countEl = document.getElementById("selected-count")
    const pluralEl = document.getElementById("selected-plural")
    
    if (countEl) {
      countEl.textContent = checkboxes.length
    }
    if (pluralEl) {
      pluralEl.textContent = checkboxes.length === 1 ? "" : "s"
    }
  }

  clearAllParticipants() {
    const checkboxes = document.querySelectorAll(".participant-checkbox")
    checkboxes.forEach(cb => cb.checked = false)
    this.updateSelectedCount()
    this.markChanged()
    this.save()
  }

  updateStatus(text, isError = false) {
    if (this.statusEl) {
      this.statusEl.textContent = text
      this.statusEl.classList.toggle("text-red-500", isError)
      this.statusEl.classList.toggle("text-gray-400", !isError)
    }
  }
}
