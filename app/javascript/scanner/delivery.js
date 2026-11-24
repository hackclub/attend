// Sends one scan, and decides what becomes of it if it can't be sent. The
// one path for the camera, search, manual entry and NFC.
import { newClientScanId } from "scanner/api"

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
// A signed ticket (scanner/ticket.js), already checked by the time it gets here.
const SIGNED_TICKET = /^T\.[A-Z2-7]+$/

// `queue()` returns the saved-scans queue (sync.js), or null where scans
// can't be saved on this device. `deliver` resolves to one of:
//
//   { status: "recorded", data }
//   { status: "queued", reason }   saved on the device, sent later by sync.js
//   { status: "failed", message, detail, reload }
//
// Only a scan the server never answered, or answered with a 5xx, is queued.
// One the server turned down (any 4xx) is over, and an expired session needs
// the operator to sign in, so both are reported instead.
export function createDelivery({ api, queue, contexts }) {
  return async function deliver(body, { label }) {
    const clientScanId = newClientScanId()
    const clientScannedAt = new Date().toISOString()
    const result = await api.postScan({ ...body, client_scan_id: clientScanId, client_scanned_at: clientScannedAt })

    if (result.outcome === "ok") {
      // The server is reachable, so anything waiting can go now too.
      queue()?.sync()
      return { status: "recorded", data: result.data }
    }
    if (result.outcome === "session") {
      return { status: "failed", message: "Your session has expired.", detail: "The scan was not recorded. Reload the page (and sign in again if asked), then scan again.", reload: true }
    }
    if (result.outcome === "refused") {
      return { status: "failed", message: result.message }
    }

    const unsaved = result.outcome === "server"
      ? { status: "failed", message: "Server error — the scan may not have been recorded.", detail: "Check Recent Scans, and scan again if it is not listed." }
      : { status: "failed", message: "Couldn't reach the server — check your connection and scan again.", detail: "The scan was not recorded." }
    if (!queue()) return unsaved

    // Offline an unsigned code can't be looked up, so only save what at least
    // has the right shape. A signed one has been checked on the device.
    const code = String(body.participant_id || "").trim()
    if (!body.badge_token && !UUID.test(code) && !SIGNED_TICKET.test(code)) {
      return { status: "failed", message: "Couldn't reach the server, and this doesn't look like an Attend code.", detail: "The scan was not recorded." }
    }

    try {
      await queue().enqueue({
        clientScanId,
        clientScannedAt,
        body,
        label,
        contextName: contexts[body.scan_context_id] || null
      })
    } catch (error) {
      console.error("Could not save the scan on this device:", error)
      return unsaved
    }
    return { status: "queued", reason: result.outcome }
  }
}
