// The check-in scanner: one island of client-side code for both admin UIs.
// The view is markup plus a mount point carrying the config; everything the
// scanner does starts here.
//
//   camera.js       the camera stream and QR decode loop
//   api.js          the calls to the server, and how each can fail
//   delivery.js     what becomes of a scan: recorded, saved for later, or failed
//   queue_store.js  scans that couldn't be sent, kept in IndexedDB
//   sync.js         sending those once the connection is back
//   nfc.js          the NFC bridge
//   ticket.js       reading a QR code, and checking a signed one on the device
//   ui.js, skins.js what it all looks like
//   offline.js      asks the service worker to keep this page loadable
import { createApi } from "scanner/api"
import { createCamera, waitForZXing } from "scanner/camera"
import { createDelivery } from "scanner/delivery"
import { createNfcBridge } from "scanner/nfc"
import { keepAvailableOffline } from "scanner/offline"
import { openQueueStore } from "scanner/queue_store"
import { createSkin } from "scanner/skins"
import { createScanQueue } from "scanner/sync"
import { INVALID_TICKET, createTicketVerifier, parseCheckinCode } from "scanner/ticket"
import { createUi } from "scanner/ui"

function readIcons(element) {
  const icons = {}
  element.querySelectorAll("template[data-scanner-icon]").forEach((template) => {
    icons[template.dataset.scannerIcon] = template.innerHTML.trim()
  })
  return icons
}

// Returns a function that tears the scanner down. Everything bound to
// document/window goes with it, so repeat visits don't stack handlers over
// detached nodes, and the camera is handed back.
export function mountScanner(element, config) {
  const pageListeners = new AbortController()
  const signal = pageListeners.signal

  const skin = createSkin(config.skin, readIcons(element))
  const api = createApi(config)
  let nfc = null
  const ui = createUi({ skin, signal, nfc: () => nfc })

  let cameraStatus = ["Initializing...", "loading"]
  let lastScannedCode = null
  let scanCooldown = false
  let searchTimeout = null
  // Scans that arrive while one is in flight or cooling down wait here rather
  // than being dropped, so a tap on a search result is never lost.
  const pendingScans = []
  // Scans that couldn't be sent at all wait in IndexedDB instead (see
  // sync.js). Null until the store opens, and for good where it can't.
  let queue = null
  // Queued scans sent since the page loaded; see ui.showSyncState.
  const sent = []

  const contextField = document.getElementById("scan-context")

  function getCurrentContextId() {
    return contextField ? contextField.value : null
  }

  // Shows the "choose a context" error and returns null when none is picked.
  function requireContextId() {
    const scanContextId = getCurrentContextId()
    if (!scanContextId) ui.showResult("Choose a context before scanning", "error")
    return scanContextId
  }

  function updateStatus(message, state = "loading") {
    document.getElementById("status-text").textContent = message
    skin.paintCameraStatus({
      wrapper: document.getElementById("camera-status"),
      dot: document.getElementById("status-dot")
    }, state)
  }

  // Camera state outlives a scan's "Processing..." flash, so remember it and
  // put it back afterwards rather than claiming the camera is ready.
  function updateCameraStatus(message, state) {
    cameraStatus = [message, state]
    if (!scanCooldown) updateStatus(message, state)
  }

  const camera = createCamera({
    onStatus: updateCameraStatus,
    onCode: (text) => processScan(text)
  })

  function renderSyncState() {
    const state = queue ? queue.snapshot() : { queued: [], rejected: [], elsewhere: 0, syncing: false, sessionExpired: false }
    ui.showSyncState(state, { sent, canQueue: Boolean(queue) })
  }

  // A queued scan reached the server. This is the first the device learns of
  // who it was, so it joins Recent Scans like any other.
  function queuedScanSent(record, data) {
    const via = record.body.badge_token ? "via NFC" : ""
    sent.push(ui.describeScan(data, via))
    ui.addToRecentScans(data.participant, data.scan_context, data.scanned_by)
    ui.updateScanCount()
  }

  const deliver = createDelivery({ api, queue: () => queue, contexts: config.contexts })
  const verifyTicket = createTicketVerifier({ keys: config.ticketKeys, eventId: config.eventId, cancelled: config.cancelledTickets })

  // `check` is what the device could tell about the code on its own (see
  // ticket.js). Online the server's answer is what counts; offline this is
  // all the operator has to go on.
  function showQueued(outcome, label, check = { verdict: "unverified" }) {
    const why = outcome.reason === "server" ? "The server had a problem." : "Couldn't reach the server."
    const later = "It will be sent automatically; who it was shows up once it has."
    if (check.verdict === "valid") {
      ui.showResult("Valid ticket · saved on this device", "success", { detail: `${label} · ${why} ${later}` })
    } else if (check.verdict === "cancelled") {
      ui.showResult("This registration was withdrawn or rejected", "error", {
        detail: `${label} · The ticket is genuine but no longer counts. Check with the event team before letting them in. The scan was saved and will be sent later.`
      })
    } else {
      ui.showResult("Saved on this device, but this code couldn't be checked", "warning", {
        detail: `${label} · ${why} Older tickets and typed IDs can only be checked online, so check their ticket another way. ${later}`
      })
    }
  }

  // The one gate for every camera, search and manual scan. Returns whether
  // the scan was sent or queued, so manual entry and search only clear what
  // staff typed once it has. `manual` is a deliberate action (search result,
  // typed ID): the camera reports the same code on every frame it stays in
  // view, so only camera repeats are ignored; anything else arriving mid-scan
  // waits its turn.
  function processScan(scannedValue, { manual = false } = {}) {
    if (scanCooldown) {
      if (!manual && (scannedValue === lastScannedCode || pendingScans.some((pending) => pending.value === scannedValue))) return false
      pendingScans.push({ value: scannedValue, manual })
      ui.showQueueNote(pendingScans.length)
      return true
    }
    if (!manual && scannedValue === lastScannedCode) return false

    const scanContextId = requireContextId()
    if (!scanContextId) {
      // Report a code held up to the camera once rather than every frame, but
      // forget it after the usual cooldown so showing it again gets feedback.
      lastScannedCode = scannedValue
      setTimeout(() => {
        if (lastScannedCode === scannedValue) lastScannedCode = null
      }, 2000)
      return false
    }

    scanCooldown = true
    lastScannedCode = scannedValue
    sendScan(scannedValue, scanContextId)
    return true
  }

  async function sendScan(scannedValue, scanContextId) {
    updateStatus("Processing...", "scanning")

    try {
      const code = parseCheckinCode(scannedValue)
      // A code that fails its signature is turned away here, online or not:
      // the server would refuse it too.
      const check = await verifyTicket(code)
      if (check.verdict === "invalid") {
        ui.showResult("Not a valid ticket", "error", { detail: `${INVALID_TICKET[check.reason]} The scan was not recorded.` })
        return finishScan()
      }

      const participantId = code.kind === "plain" ? code.id : code.token
      const label = code.kind === "signed"
        ? `Ticket ${code.participantEventId.slice(0, 8).toUpperCase()}`
        : `ID ${String(participantId).trim().slice(0, 8).toUpperCase()}`
      const outcome = await deliver({ participant_id: participantId, scan_context_id: scanContextId }, { label })

      if (outcome.status === "recorded") {
        const data = outcome.data
        ui.showScanSuccess(data)

        ui.showParticipantModal(data.participant, data.scan_context, data.first_scan_in_context)
        ui.addToRecentScans(data.participant, data.scan_context, data.scanned_by)
        ui.updateScanCount()

        // Offer NFC write if enabled, check-in context, and badge not yet assigned
        if (nfc.writeOnCheckinEnabled &&
            nfc.isConnected() &&
            data.scan_context?.checks_in &&
            data.participant.nfc_badge_token &&
            !data.participant.nfc_badge_assigned) {
          if (!data.participant.slack_user_id) {
            console.warn("NFC write skipped: participant missing slack_user_id")
          } else {
            nfc.showWritePanel(
              data.participant.display_name,
              data.participant.participant_event_id,
              data.participant.nfc_badge_token,
              data.participant.slack_user_id
            )
          }
        }
      } else if (outcome.status === "queued") {
        showQueued(outcome, label, check)
      } else {
        ui.showResult(outcome.message, "error", { detail: outcome.detail, reload: outcome.reload })
      }
    } catch (error) {
      // Anything thrown here is our own rendering, after the server answered.
      console.error("Scan error:", error)
      ui.showResult("Something went wrong showing this scan.", "error", { detail: "Check Recent Scans to see whether it was recorded." })
    }

    finishScan()
  }

  // The cooldown after every scan, recorded or not, before the next one.
  function finishScan() {
    setTimeout(() => {
      if (signal.aborted) return
      scanCooldown = false
      lastScannedCode = null
      updateStatus(...cameraStatus)
      const next = pendingScans.shift()
      ui.showQueueNote(pendingScans.length)
      if (next) processScan(next.value, { manual: next.manual })
    }, 2000)
  }

  // A badge tap from the NFC bridge. Not held back by the camera's cooldown.
  async function processNfcScan(badgeToken) {
    const scanContextId = getCurrentContextId()
    if (!scanContextId) {
      ui.showResult("Choose a context before scanning", "error")
      return
    }

    try {
      const outcome = await deliver({ badge_token: badgeToken, scan_context_id: scanContextId }, { label: "NFC badge" })

      if (outcome.status === "recorded") {
        ui.showScanSuccess(outcome.data, "via NFC")
        ui.showParticipantModal(outcome.data.participant, outcome.data.scan_context, outcome.data.first_scan_in_context)
      } else if (outcome.status === "queued") {
        showQueued(outcome, "NFC badge")
      } else {
        ui.showResult(outcome.message, "error", { detail: outcome.detail, reload: outcome.reload })
      }
    } catch (error) {
      console.error("NFC scan error:", error)
      ui.showResult("Something went wrong showing this NFC scan.", "error", { detail: "Check Recent Scans to see whether it was recorded." })
    }
  }

  nfc = createNfcBridge({ config, api, skin, signal, scan: processNfcScan, showResult: ui.showResult })

  async function writeNfcBadgeFromModal() {
    const data = ui.modalParticipant()
    if (!data) return

    const status = document.getElementById("modal-nfc-status")

    // If no badge token, fetch/generate one first
    let badgeToken = data.nfc_badge_token
    if (!badgeToken) {
      if (status) status.textContent = "Generating badge token..."
      try {
        badgeToken = await api.ensureNfcBadgeToken(data.participant_event_id)
        if (!badgeToken) {
          if (status) status.textContent = "Failed to generate badge token"
          return
        }
        data.nfc_badge_token = badgeToken
      } catch (error) {
        console.error("Error generating badge token:", error)
        if (status) status.textContent = "Error generating badge token"
        return
      }
    }

    // Close the modal and show the write panel
    ui.closeModal()
    nfc.showWritePanel(data.display_name, data.participant_event_id, badgeToken, data.slack_user_id || "")
  }

  document.getElementById("modal-write-nfc-btn")?.addEventListener("click", writeNfcBadgeFromModal, { signal })

  // Manual form submission
  document.getElementById("manual-scan-form").addEventListener("submit", function(event) {
    event.preventDefault()
    const input = document.getElementById("manual-participant-id")
    const participantId = input.value.trim()
    if (participantId && processScan(participantId, { manual: true })) {
      input.value = ""
    }
  }, { signal })

  // Search functionality
  const searchInput = document.getElementById("participant-search")
  const searchResults = document.getElementById("search-results")

  searchInput.addEventListener("input", function() {
    const query = this.value.trim()

    if (searchTimeout) clearTimeout(searchTimeout)

    if (query.length < 2) {
      searchResults.classList.add("hidden")
      return
    }

    searchTimeout = setTimeout(async () => {
      const { results, error } = await api.searchParticipants(query)
      if (signal.aborted) return

      if (error === "session") {
        searchResults.innerHTML = skin.searchNotice("Your session has expired — reload the page to search.", "error").toString()
      } else if (error === "failed") {
        searchResults.innerHTML = skin.searchNotice("Search failed — try again.", "error").toString()
      } else if (error) {
        searchResults.innerHTML = skin.searchNotice("Couldn't reach the server — check your connection.", "error").toString()
      } else if (!results || results.length === 0) {
        searchResults.innerHTML = skin.searchNotice("No participants found", "empty").toString()
      } else {
        searchResults.innerHTML = results.map((participant) => skin.searchResult(participant)).join("")
      }
      searchResults.classList.remove("hidden")
    }, 300)
  }, { signal })

  // Handle search result click
  searchResults.addEventListener("click", function(event) {
    const result = event.target.closest(".search-result")
    if (result && processScan(result.dataset.participantId, { manual: true })) {
      searchInput.value = ""
      searchResults.classList.add("hidden")
    }
  }, { signal })

  // Hide search results when clicking outside
  document.addEventListener("click", function(event) {
    if (!searchInput.contains(event.target) && !searchResults.contains(event.target)) {
      searchResults.classList.add("hidden")
    }
  }, { signal })

  // With several contexts the camera waits until staff pick one (see the
  // change handler): every scan is refused until then and the overlay hides
  // the video anyway.
  let scannerStarted = false
  function startScannerOnce() {
    if (scannerStarted) return
    scannerStarted = true
    waitForZXing().then(() => {
      if (!signal.aborted) camera.start()
    })
  }

  // Staff must pick a context themselves: until they do, flag the selector
  // and cover the camera with an empty state. Start from the placeholder even
  // if the browser restored an earlier choice, since that fires no change.
  const contextSelect = document.querySelector("select#scan-context")
  if (contextSelect) {
    contextSelect.value = ""
    contextSelect.addEventListener("change", () => {
      contextSelect.removeAttribute("aria-invalid")
      contextSelect.removeAttribute("aria-describedby")
      document.getElementById("scan-context-required")?.classList.add("hidden")
      lastScannedCode = null
      startScannerOnce()
    }, { signal })
    updateStatus("Choose a context")
  } else {
    startScannerOnce()
  }

  // The saved-scans panel and the queue behind it.
  document.getElementById("scan-sync").addEventListener("click", function(event) {
    const target = (attribute) => event.target.closest(`[${attribute}]`)
    if (target("data-scan-sync-reload")) window.location.reload()
    if (!queue) return

    if (target("data-scan-sync-now")) queue.sync()
    const dismissed = target("data-scan-sync-dismiss")
    if (dismissed) queue.dismiss(dismissed.getAttribute("data-scan-sync-dismiss"))
    if (target("data-scan-sync-clear")) {
      sent.length = 0
      renderSyncState()
    }
    if (target("data-scan-sync-discard") && window.confirm("Discard the scans saved on this device? They will never be recorded.")) {
      queue.discardQueued()
    }
  }, { signal })

  window.addEventListener("online", renderSyncState, { signal })
  window.addEventListener("offline", renderSyncState, { signal })
  renderSyncState()

  openQueueStore().then(async (store) => {
    if (signal.aborted) return store.close()
    signal.addEventListener("abort", () => store.close())

    const scanQueue = createScanQueue({
      store,
      api,
      scope: { eventId: config.eventId, userId: config.userId },
      signal,
      onChange: renderSyncState,
      onSynced: queuedScanSent
    })
    await scanQueue.load()
    queue = scanQueue
    renderSyncState()
    queue.sync()
  }).catch((error) => {
    // Without IndexedDB the scanner works as it always did: a scan that
    // can't be sent is reported as not recorded.
    console.warn("Scans can't be saved on this device:", error)
    renderSyncState()
  })

  keepAvailableOffline(config)

  // Hand the camera back as soon as we navigate away, otherwise iOS keeps the
  // capture (and its indicator) alive behind the next page.
  function teardown() {
    camera.stop()
    pageListeners.abort()
  }
  document.addEventListener("turbo:before-render", teardown, { signal })

  return teardown
}
