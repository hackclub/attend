// The NFC bridge: a WebSocket to the Attend NFC Bridge app running on the
// same machine, which reads badge taps and writes new badges.
const BRIDGE_URL = "ws://localhost:9876"

// `scan(badgeToken)` records a badge tap; `showResult` is the scan banner.
export function createNfcBridge({ config, api, skin, signal, scan, showResult }) {
  let socket = null
  let pendingWrite = null

  const statusWrapper = document.getElementById("nfc-status")
  const statusDot = document.getElementById("nfc-status-dot")
  const statusText = document.getElementById("nfc-status-text")
  const connectButton = document.getElementById("nfc-connect-btn")
  const writePanel = document.getElementById("nfc-write-panel")
  const writeCancel = document.getElementById("nfc-write-cancel")
  const writeParticipantName = document.getElementById("nfc-write-participant-name")
  const writeStatus = document.getElementById("nfc-write-status")

  const BUTTON_LABELS = { connected: "Disconnect", connecting: "Connecting...", error: "Retry" }

  function updateStatus(status, message) {
    if (!statusDot || !statusText) return

    skin.paintNfcStatus({ wrapper: statusWrapper, dot: statusDot }, status)
    connectButton.textContent = BUTTON_LABELS[status] || "Connect"
    statusText.textContent = message
  }

  function isConnected() {
    return Boolean(socket && socket.readyState === WebSocket.OPEN)
  }

  function connect() {
    if (isConnected()) {
      socket.close()
      socket = null
      updateStatus("disconnected", "Not connected")
      return
    }

    updateStatus("connecting", "Connecting...")

    try {
      socket = new WebSocket(BRIDGE_URL)

      socket.onopen = function() {
        updateStatus("connected", "Ready to scan")
      }

      socket.onclose = function() {
        updateStatus("disconnected", "Disconnected")
        socket = null
      }

      socket.onerror = function() {
        updateStatus("error", "Bridge not running")
        socket = null
      }

      socket.onmessage = function(event) {
        handleMessage(JSON.parse(event.data))
      }
    } catch (_) {
      updateStatus("error", "Connection failed")
    }
  }

  function handleMessage(data) {
    switch (data.type) {
      case "tag_read":
        handleTagRead(data.tag)
        break
      case "write_result":
        handleWriteResult(data)
        break
      case "write_pending":
        if (writeStatus) writeStatus.textContent = "Tap badge to reader..."
        break
    }
  }

  function handleTagRead(tag) {
    // If we're in write mode (waiting for write or verifying), don't process as normal scan
    if (pendingWrite) {
      if (pendingWrite.verifying) {
        // Verify the written badge - check for attend token in external record
        if (tag.attendToken === pendingWrite.token) {
          confirmBadge(pendingWrite.participantEventId, pendingWrite.token)
        } else if (writeStatus) {
          writeStatus.textContent = "Badge mismatch! Try again."
        }
      } else if (writeStatus) {
        // Still waiting for write - tag was tapped, bridge should handle writing
        writeStatus.textContent = "Writing..."
      }
      return
    }

    // Normal NFC scan - use attend token from external record
    if (tag.attendToken) {
      scan(tag.attendToken)
    } else {
      console.log("Tag has no attendToken, showing as unrecognized")
      showResult("Unrecognized NFC tag - no badge data found", "error")
    }
  }

  function handleWriteResult(data) {
    if (data.success) {
      if (writeStatus) writeStatus.textContent = "Written! Tap again to verify..."
      if (pendingWrite) pendingWrite.verifying = true
    } else if (writeStatus) {
      writeStatus.textContent = "Write failed: " + (data.error || "Unknown error")
    }
  }

  async function confirmBadge(participantEventId, token) {
    try {
      if (await api.confirmNfcBadge(participantEventId, token)) {
        if (writeStatus) writeStatus.textContent = "✓ Badge assigned successfully!"
        setTimeout(hideWritePanel, 2000)
      } else if (writeStatus) {
        writeStatus.textContent = "Confirmation failed"
      }
    } catch (_) {
      if (writeStatus) writeStatus.textContent = "Error confirming badge"
    }

    pendingWrite = null
  }

  function showWritePanel(participantName, participantEventId, token, slackUserId) {
    if (!writePanel) return

    writeParticipantName.textContent = participantName
    writeStatus.textContent = "Waiting for badge..."
    writePanel.classList.remove("hidden")

    pendingWrite = { participantEventId, token, slackUserId, verifying: false }

    // Send write command to bridge with both payloads
    if (isConnected()) {
      socket.send(JSON.stringify({
        action: "write",
        badge_url: "https://badge.hackclub.com/t/" + slackUserId,
        attend_token: token
      }))
    } else {
      writeStatus.textContent = "NFC bridge not connected"
    }
  }

  function hideWritePanel() {
    if (writePanel) writePanel.classList.add("hidden")
    pendingWrite = null
  }

  if (connectButton) connectButton.addEventListener("click", connect, { signal })
  if (writeCancel) writeCancel.addEventListener("click", hideWritePanel, { signal })

  // Auto-connect on page load
  const autoConnect = setTimeout(connect, 1000)

  // Disconnect when we navigate away, otherwise the next visit opens a second
  // connection and every tap is scanned twice.
  signal.addEventListener("abort", function() {
    clearTimeout(autoConnect)
    if (socket) socket.close()
  })

  return { isConnected, showWritePanel, writeOnCheckinEnabled: config.nfcWriteOnCheckin }
}
