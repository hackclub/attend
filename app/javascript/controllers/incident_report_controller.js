import { Controller } from "@hotwired/stimulus"

// Persists the incident form across an OAuth login round-trip (via localStorage),
// prompts HQ/Participant reporters to log in, and validates attachment sizes client-side.
export default class extends Controller {
  static targets = [
    "persist", "role", "loginPrompt", "fileInput", "fileError",
    "incidentType", "medicalQuestion", "emergencyServices", "priority", "priorityLock",
    "eventSelect"
  ]
  static values = { signedIn: Boolean }

  static STORAGE_KEY = "incident_report_draft"
  static MAX_FILE_BYTES = 25 * 1024 * 1024
  static MAX_FILE_COUNT = 10
  static PROMPT_ROLES = ["hq_employee", "participant"]

  connect() {
    this.restore()
    this.persistTargets.forEach((el) => {
      el.addEventListener("input", () => this.save())
      el.addEventListener("change", () => this.save())
    })
    this.roleChanged()
    this.eventChanged()
    this.incidentTypeChanged()
  }

  // Emergency priority is only offered for current/recent events (not custom/old ones).
  emergencyAllowed() {
    if (!this.hasEventSelectTarget) return true
    const opt = this.eventSelectTarget.selectedOptions[0]
    return !opt || opt.dataset.emergencyAllowed !== "false"
  }

  eventChanged() {
    if (!this.hasPriorityTarget) return
    const allowed = this.emergencyAllowed()
    const emergencyOption = this.priorityTarget.querySelector('option[value="emergency"]')
    if (emergencyOption) emergencyOption.disabled = !allowed

    if (!allowed && this.priorityTarget.value === "emergency") {
      this.priorityTarget.value = "standard"
    }
    this.emergencyServicesChanged()
  }

  save() {
    const draft = {}
    this.persistTargets.forEach((el) => {
      if (!el.name) return
      if (el.type === "checkbox") {
        draft[el.name] = el.checked
      } else if (el.type === "tel" && el.iti) {
        // Save the full +country number, not the national digits on screen, so
        // the chosen country survives the login round-trip.
        draft[el.name] = el.iti.getNumber() || el.value
      } else {
        draft[el.name] = el.value
      }
    })
    try {
      localStorage.setItem(this.constructor.STORAGE_KEY, JSON.stringify(draft))
    } catch (_e) {
      // ignore storage failures (private mode, quota)
    }
  }

  // Only fill fields that are currently empty so server-prefilled identity wins.
  restore() {
    let draft
    try {
      draft = JSON.parse(localStorage.getItem(this.constructor.STORAGE_KEY) || "{}")
    } catch (_e) {
      return
    }
    this.persistTargets.forEach((el) => {
      if (!(el.name in draft)) return
      if (el.type === "checkbox") {
        el.checked = draft[el.name]
      } else if (draft[el.name] && !el.value) {
        el.value = draft[el.name]
      }
    })
  }

  incidentTypeChanged() {
    if (!this.hasMedicalQuestionTarget || !this.hasIncidentTypeTarget) return
    const isMedical = this.incidentTypeTarget.value === "medical_emergency"
    this.medicalQuestionTarget.classList.toggle("hidden", !isMedical)

    // The checkbox only applies to medical emergencies — reset it otherwise.
    if (!isMedical && this.hasEmergencyServicesTarget) {
      this.emergencyServicesTarget.checked = false
    }
    this.emergencyServicesChanged()
  }

  emergencyServicesChanged() {
    if (!this.hasPriorityTarget) return
    // Forcing emergency only applies when the chosen event still allows it.
    const force = this.hasEmergencyServicesTarget && this.emergencyServicesTarget.checked && this.emergencyAllowed()

    if (force) {
      this.priorityTarget.value = "emergency"
      this.priorityTarget.disabled = true
    } else {
      this.priorityTarget.disabled = false
    }

    if (this.hasPriorityLockTarget) {
      this.priorityLockTarget.classList.toggle("hidden", !force)
    }
    this.save()
  }

  roleChanged() {
    if (!this.hasLoginPromptTarget) return
    const show =
      !this.signedInValue &&
      this.hasRoleTarget &&
      this.constructor.PROMPT_ROLES.includes(this.roleTarget.value)
    this.loginPromptTarget.classList.toggle("hidden", !show)
  }

  validateFiles() {
    if (!this.hasFileInputTarget || !this.hasFileErrorTarget) return
    const files = Array.from(this.fileInputTarget.files || [])
    let error = ""

    if (files.length > this.constructor.MAX_FILE_COUNT) {
      error = `Please attach at most ${this.constructor.MAX_FILE_COUNT} files.`
    } else {
      const tooBig = files.find((f) => f.size > this.constructor.MAX_FILE_BYTES)
      if (tooBig) error = `"${tooBig.name}" is larger than 25MB. Please attach a smaller file.`
    }

    if (error) {
      this.fileErrorTarget.textContent = error
      this.fileErrorTarget.classList.remove("hidden")
      this.fileInputTarget.value = ""
    } else {
      this.fileErrorTarget.classList.add("hidden")
    }
  }

  clearDraft() {
    try {
      localStorage.removeItem(this.constructor.STORAGE_KEY)
    } catch (_e) {
      // ignore
    }
  }
}
