import { Controller } from "@hotwired/stimulus"

// Clears the saved incident-report draft once the report has been submitted.
export default class extends Controller {
  connect() {
    try {
      localStorage.removeItem("incident_report_draft")
    } catch (_e) {
      // ignore
    }
  }
}
