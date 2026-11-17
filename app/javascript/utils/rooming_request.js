// Requests the rooming wizard's assignments step makes from Stimulus
// (rooming_assignments_controller, rooming_staff_modal_controller). Each one
// goes to an existing RoomingWizardController action; the controllers render
// the turbo stream that comes back.
import { Turbo } from "@hotwired/turbo-rails"

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content
}

// `body` is a FormData, or a plain object sent form-urlencoded. `stream: true`
// asks for a turbo stream, which is how these actions return the re-rendered
// summary bar, sidebar and room cards.
export function roomingRequest(url, { method = "POST", body = {}, stream = false } = {}) {
  const headers = { "X-CSRF-Token": csrfToken() }
  if (stream) headers["Accept"] = "text/vnd.turbo-stream.html"
  if (!(body instanceof FormData)) {
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    body = new URLSearchParams(body).toString()
  }

  return fetch(url, { method, headers, body })
}

// Renders a successful turbo-stream response. Stimulus connects the
// controllers on whatever it replaces, so nothing needs re-binding.
export async function renderStream(response) {
  Turbo.renderStreamMessage(await response.text())
}

// The server's `{ error: "…" }` for a refused change, or the fallback when
// the response isn't JSON (a 403 on a locked plan, a 500).
export async function errorMessage(response, fallback) {
  try {
    const data = await response.json()
    return data.error || fallback
  } catch {
    return fallback
  }
}
