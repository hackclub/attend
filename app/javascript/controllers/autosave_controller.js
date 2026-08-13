import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    url: String,
    createUrl: String
  }

  connect() {
    this.timeout = null
    this.inFlight = false
    this.queued = false
    this.statusEl = document.getElementById("save-status")
  }

  disconnect() {
    if (this.timeout) {
      clearTimeout(this.timeout)
    }
  }

  input(event) {
    this.debouncedSave()
  }

  change(event) {
    this.debouncedSave()
  }

  debouncedSave() {
    if (!this.shouldSave()) return

    if (this.timeout) {
      clearTimeout(this.timeout)
    }

    this.updateStatus("Saving...")

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

  save() {
    if (this.timeout) {
      clearTimeout(this.timeout)
      this.timeout = null
    }

    if (!this.shouldSave()) return

    // Only one save on the wire at a time. On a slow connection two overlapping
    // PATCHes write the same rows concurrently and can deadlock each other, so
    // coalesce anything that happens mid-flight into a single follow-up save.
    if (this.inFlight) {
      this.queued = true
      return
    }

    const persisted = this.isPersisted()
    const form = this.element
    const formData = new FormData(form)
    formData.append('autosave', 'true')

    // File inputs only matter on a real submit — resending them on every
    // autosave re-uploads the whole file and churns Active Storage records.
    form.querySelectorAll('input[type="file"]').forEach((input) => {
      if (input.name) formData.delete(input.name)
    })

    this.inFlight = true
    this.updateStatus("Saving...")

    fetch(persisted ? this.urlValue : this.createUrlValue, {
      method: persisted ? "PATCH" : "POST",
      headers: {
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
      },
      body: formData
    })
    .then(response => response.json())
    .then(data => {
      if (data.success) {
        if (!persisted) {
          this.markPersisted(data)
        }
        const time = new Date(data.saved_at)
        this.updateStatus(`Saved at ${time.toLocaleTimeString()}`)
      } else {
        this.updateStatus("Save failed", true)
      }
    })
    .catch(error => {
      console.error("Autosave error:", error)
      this.updateStatus("Save failed", true)
    })
    .finally(() => {
      this.inFlight = false
      if (this.queued) {
        this.queued = false
        this.save()
      }
    })
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
