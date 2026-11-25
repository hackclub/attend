// The scanner's calls to the server. Nothing here touches the page, and no
// response is kept anywhere but the caller's memory.

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content
}

function isJson(response) {
  return (response.headers.get("content-type") || "").includes("application/json")
}

// A scan's own id, repeated on every retry so the server records it once.
export function newClientScanId() {
  if (window.crypto?.randomUUID) return window.crypto.randomUUID()
  const bytes = window.crypto.getRandomValues(new Uint8Array(16))
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
}

export function createApi(config) {
  // POSTs a scan and sorts every way it can end into one of:
  //
  //   ok          recorded (or already recorded under this client_scan_id)
  //   unreachable no answer at all: offline, DNS, a dropped connection
  //   server      a 5xx; with the client_scan_id a retry is safe
  //   session     signed out, CSRF token stale, or access to the event lost.
  //               These all come back as a redirect to an HTML page, not
  //               JSON, so the content type is checked before parsing.
  //   refused     any other 4xx: the server understood and said no
  //
  // Only `unreachable` and `server` are worth retrying.
  async function postScan(body) {
    let response
    try {
      response = await fetch(config.scanUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken()
        },
        body: JSON.stringify({ ...body, client_sent_at: new Date().toISOString() })
      })
    } catch (error) {
      console.error("Scan request failed:", error)
      return { outcome: "unreachable" }
    }

    let data = null
    if (isJson(response)) {
      try { data = await response.json() } catch (_) { data = null }
    }

    if (response.ok && data && data.success) return { outcome: "ok", data }

    if (response.status === 401 || response.status === 403 || response.redirected || (response.ok && !data)) {
      return { outcome: "session" }
    }
    if (response.status >= 500) return { outcome: "server", status: response.status }
    if (response.status === 404) {
      return { outcome: "refused", status: 404, message: data?.error || "Participant not found for this event" }
    }
    return {
      outcome: "refused",
      status: response.status,
      message: data?.error || `The scan couldn't be processed (error ${response.status}).`
    }
  }

  // Resolves to { results } or { error: "session" | "failed" | "unreachable" }.
  async function searchParticipants(query) {
    let response
    try {
      response = await fetch(`${config.searchUrl}?q=${encodeURIComponent(query)}`, {
        headers: { "Accept": "application/json" }
      })
    } catch (error) {
      console.error("Search error:", error)
      return { error: "unreachable" }
    }
    if (!response.ok || !isJson(response) || response.redirected) {
      const expired = response.redirected || response.status === 401 || (response.ok && !isJson(response))
      return { error: expired ? "session" : "failed" }
    }
    try {
      return { results: (await response.json()).results }
    } catch (error) {
      console.error("Search error:", error)
      return { error: "unreachable" }
    }
  }

  // Resolves to the badge token, or throws / returns null when there is none.
  async function ensureNfcBadgeToken(participantEventId) {
    const response = await fetch(config.nfcEnsureUrl.replace(":id", encodeURIComponent(participantEventId)), {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken() }
    })
    const result = await response.json()
    return response.ok && result.badge_token ? result.badge_token : null
  }

  async function confirmNfcBadge(participantEventId, token) {
    const response = await fetch(config.nfcConfirmUrl.replace(":id", encodeURIComponent(participantEventId)), {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
      body: JSON.stringify({ badge_token: token })
    })
    return response.ok
  }

  return { postScan, searchParticipants, ensureNfcBadgeToken, confirmNfcBadge }
}
