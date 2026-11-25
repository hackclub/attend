// What the scanner shows: the result banner, the participant modal, the
// recent scans list and the saved-scans panel. Classes and markup come from
// the skin, so both admin UIs share this.
import { html } from "utils/html"

function formatStatus(participant) {
  return participant.display_status || String(participant.status || "").replace(/_/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase())
}

function formatTime(value) {
  const at = value ? new Date(value) : new Date()
  return at.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
}

function plural(count, noun) {
  return `${count} ${noun}${count === 1 ? "" : "s"}`
}

export function createUi({ skin, signal, nfc }) {
  const resultElement = document.getElementById("scan-result")
  const syncElement = document.getElementById("scan-sync")
  const modal = document.getElementById("participant-modal")
  let modalParticipant = null

  // `tone` is 'success' / 'warning' / 'error'.
  function showResult(message, tone = "success", { detail = null, reload = false } = {}) {
    skin.paintResult(resultElement, tone, { message, detail, reload })
    resultElement.classList.remove("hidden")
  }

  resultElement.addEventListener("click", function(event) {
    if (event.target.closest("[data-scan-result-dismiss]")) this.classList.add("hidden")
    if (event.target.closest("[data-scan-result-reload]")) window.location.reload()
  }, { signal })

  // What the scan actually did, in words: where, the person's resulting
  // status, who scanned them and when.
  function describeScan(data, via = "") {
    const name = data.participant.display_name
    const context = data.scan_context || {}
    const contextName = context.name || "this scan point"
    const firstScan = data.first_scan_in_context
    let message = skin.scanMessagePrefix(firstScan)
    if (context.checks_in) {
      message += firstScan ? `${name} checked in to ${contextName}` : `${name} was already checked in to ${contextName}`
    } else {
      message += firstScan ? `${name} scanned at ${contextName}` : `${name} re-scanned at ${contextName}`
    }
    if (via) message += ` ${via}`

    const status = formatStatus(data.participant)
    const time = formatTime(data.scanned_at)
    // At a stay's arrival point: their room, or a warning that they have none.
    const stay = data.stay
    const notRoomed = stay && !stay.room
    if (notRoomed) message += ` · no room in ${stay.name}`
    const detail = [stay && stay.room && `Room ${stay.room}`, status && `Status: ${status}`, data.scanned_by && `by ${data.scanned_by}`, time].filter(Boolean).join(" · ")

    const flagged = ["Withdrawn", "Rejected"].includes(data.participant.display_status)
    return { message, detail, tone: flagged || notRoomed || !firstScan ? "warning" : "success" }
  }

  function showScanSuccess(data, via = "") {
    const { message, detail, tone } = describeScan(data, via)
    showResult(message, tone, { detail })
  }

  function showParticipantModal(data, scanContext, firstScan) {
    const actionText = document.getElementById("modal-action-text")

    // Store participant data for NFC write button
    modalParticipant = data

    // Update header based on whether it's first scan or re-scan
    if (firstScan) {
      actionText.textContent = scanContext?.checks_in ? "Checked In" : "Scanned"
    } else {
      actionText.textContent = "Already Scanned"
    }
    skin.paintModalHeader({ header: document.getElementById("modal-header"), actionText }, firstScan)

    document.getElementById("modal-context-name").textContent = scanContext?.name ? "@ " + scanContext.name : ""

    document.getElementById("modal-name").textContent = data.display_name
    const groupsElement = document.getElementById("modal-groups")
    if (groupsElement) {
      groupsElement.innerHTML = (data.groups && data.groups.length)
        ? data.groups.map((group) => skin.groupBadge(group, skin.modalGroupFallback)).join("")
        : ""
    }
    document.getElementById("modal-status").textContent = data.display_status || data.status.replace("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase())
    document.getElementById("modal-pronouns").textContent = data.pronouns || "—"
    document.getElementById("modal-email").textContent = data.email || "—"
    // The phone row is absent for roles that can't see phone numbers, and the
    // lookup response leaves the field out for them too.
    const phoneElement = document.getElementById("modal-phone")
    if (phoneElement) phoneElement.textContent = data.phone || "—"
    document.getElementById("modal-tshirt").textContent = data.tshirt_size?.toUpperCase() || "—"
    // The diet type plus the food-allergy flags, so a recorded allergy never
    // reads as "None specified".
    const dietaryParts = [
      data.dietary?.replace("_", " "),
      data.has_life_threatening_food_allergies && "life-threatening food allergies",
      data.cross_contamination_risk && "cross-contamination risk",
      data.has_allergies && "allergies on health form"
    ].filter(Boolean)
    document.getElementById("modal-dietary").textContent = dietaryParts.join(" · ") || "None specified"
    document.getElementById("modal-view-link").href = data.show_url

    // Health-form allergies can be food allergies too (older records often put
    // them there), so they get an alert rather than only the muted Dietary line.
    document.getElementById("modal-alerts").innerHTML = [
      data.has_anaphylaxis_risk && skin.modalAlert("anaphylaxis"),
      data.has_life_threatening_food_allergies && skin.modalAlert("food_allergies"),
      data.has_allergies && skin.modalAlert("health_form_allergies"),
      data.requires_refrigeration && skin.modalAlert("refrigeration")
    ].filter(Boolean).join("")

    // Show NFC section if NFC is enabled and bridge is connected
    const nfcSection = document.getElementById("modal-nfc-section")
    if (nfcSection) {
      if (nfc().isConnected()) {
        nfcSection.classList.remove("hidden")
        const buttonText = document.getElementById("modal-nfc-btn-text")
        const status = document.getElementById("modal-nfc-status")
        if (data.nfc_badge_assigned) {
          buttonText.textContent = "Rewrite NFC Badge"
          status.textContent = "Badge already assigned - rewrite will update the badge"
        } else {
          buttonText.textContent = "Write NFC Badge"
          status.textContent = data.slack_user_id ? "" : "Missing Slack ID - badge URL will be limited"
        }
      } else {
        nfcSection.classList.add("hidden")
      }
    }

    modal.classList.remove("hidden")
    modal.classList.add("flex")
  }

  function closeModal() {
    modal.classList.add("hidden")
    modal.classList.remove("flex")
  }

  modal.addEventListener("click", function(event) {
    if (event.target === this) closeModal()
  }, { signal })

  document.querySelectorAll("[data-close-participant-modal]").forEach((element) => {
    element.addEventListener("click", closeModal, { signal })
  })

  function addToRecentScans(participant, scanContext, scannedBy) {
    const container = document.getElementById("recent-scans")
    const emptyMessage = container.querySelector(skin.recentEmptySelector)
    if (emptyMessage) emptyMessage.remove()

    container.insertAdjacentHTML("afterbegin", skin.recentScan({ participant, scanContext, scannedBy }).toString())

    setTimeout(() => {
      const firstChild = container.firstElementChild
      if (firstChild) firstChild.classList.remove(skin.recentHighlight)
    }, 2000)
  }

  function updateScanCount() {
    const count = document.getElementById("scan-count")
    if (count) count.textContent = parseInt(count.textContent) + 1
  }

  function showQueueNote(waiting) {
    const note = document.getElementById("scan-queue-note")
    if (waiting) {
      note.textContent = `Please wait… ${waiting} more scan${waiting === 1 ? "" : "s"} queued.`
      note.classList.remove("hidden")
    } else {
      note.classList.add("hidden")
    }
  }

  // The saved-scans panel: what is waiting on this device, what has since
  // been sent, and anything the server turned down once it could be asked.
  // `sent` is the scans sent since the page loaded, held in memory only since
  // it is where names come back from the server.
  function showSyncState({ queued, rejected, elsewhere, syncing, sessionExpired }, { sent, canQueue }) {
    const button = (label, attribute, value = "") => html`<button type="button" ${attribute}="${value}" class="${skin.syncButton}">${label}</button>`
    const describe = (record) => [record.label, formatTime(record.clientScannedAt), record.contextName].filter(Boolean).join(" · ")
    const blocks = []

    if (!navigator.onLine) {
      blocks.push(skin.syncNotice("warning", html`
        <p class="font-bold">You're offline</p>
        <p class="${skin.syncDetail}">${canQueue
          ? "Scans are saved on this device and sent when the connection is back. Names, status and medical alerts can't be shown until then."
          : "This browser can't save scans for later, so nothing scanned now will be recorded."}</p>
      `))
    }

    if (queued.length && sessionExpired) {
      blocks.push(skin.syncNotice("error", html`
        <p class="font-bold">Can't send ${plural(queued.length, "saved scan")}</p>
        <p class="${skin.syncDetail}">Your session has expired, or you no longer have access to this event. The scans stay on this device: reload the page and sign in again to send them.</p>
        <p class="flex flex-wrap gap-x-4">${button("Reload page", "data-scan-sync-reload")}${button("Discard saved scans", "data-scan-sync-discard")}</p>
      `))
    } else if (queued.length) {
      const listed = queued.slice(0, 5)
      blocks.push(skin.syncNotice("warning", html`
        <p class="font-bold">${plural(queued.length, "scan")} saved on this device, not sent yet</p>
        <p class="${skin.syncDetail}">${syncing ? "Sending now…" : "Will send automatically when the server can be reached."}</p>
        <ul class="${skin.syncDetail}">
          ${listed.map((record) => html`<li>${describe(record)}</li>`)}
          ${queued.length > listed.length ? html`<li>and ${queued.length - listed.length} more</li>` : ""}
        </ul>
        ${syncing ? "" : button("Send now", "data-scan-sync-now")}
      `))
    }

    rejected.forEach((record) => {
      blocks.push(skin.syncNotice("error", html`
        <p class="font-bold">A saved scan was not recorded</p>
        <p class="${skin.syncDetail}">${describe(record)}: ${record.error || "the server turned it down."}</p>
        ${button("Dismiss", "data-scan-sync-dismiss", record.clientScanId)}
      `))
    })

    if (sent.length) {
      const listed = sent.slice(-10)
      blocks.push(skin.syncNotice(sent.some((entry) => entry.tone !== "success") ? "warning" : "success", html`
        <p class="font-bold">Sent ${plural(sent.length, "saved scan")}</p>
        <ul class="${skin.syncDetail}">
          ${sent.length > listed.length ? html`<li>${sent.length - listed.length} earlier</li>` : ""}
          ${listed.map((entry) => html`<li>${entry.message}${entry.detail ? ` (${entry.detail})` : ""}</li>`)}
        </ul>
        ${button("Dismiss", "data-scan-sync-clear")}
      `))
    }

    if (elsewhere) {
      blocks.push(skin.syncNotice("info", html`
        <p class="${skin.syncDetail}">${plural(elsewhere, "saved scan")} on this device ${elsewhere === 1 ? "belongs" : "belong"} to another event or sign-in, and will send when that scanner is open.</p>
      `))
    }

    syncElement.innerHTML = blocks.join("")
    syncElement.classList.toggle("hidden", blocks.length === 0)
  }

  return {
    showResult,
    describeScan,
    showScanSuccess,
    showParticipantModal,
    closeModal,
    addToRecentScans,
    updateScanCount,
    showQueueNote,
    showSyncState,
    modalParticipant: () => modalParticipant
  }
}
