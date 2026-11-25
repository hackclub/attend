// The camera and the QR decode loop. ZXing arrives as a classic script in
// <head> (app/javascript/vendor/zxing.min.js), so it is read off the global.
import { html } from "utils/html"

const CAMERA_STORAGE_KEY = "scannerCameraId"

function zxing() {
  return typeof window.ZXing !== "undefined" && window.ZXing.QRCodeReader ? window.ZXing : null
}

// The zxing tag lives in <head>, and on a Turbo visit Turbo appends it
// without waiting for it to load, so poll for the global rather than betting
// on a fixed delay.
export function waitForZXing(timeoutMs = 8000) {
  return new Promise((resolve) => {
    const deadline = performance.now() + timeoutMs
    ;(function poll() {
      if (zxing()) return resolve()
      if (performance.now() > deadline) return resolve()
      setTimeout(poll, 50)
    })()
  })
}

function storedCameraId() {
  try {
    return localStorage.getItem(CAMERA_STORAGE_KEY)
  } catch (_) {
    return null
  }
}

// Maps a getUserMedia rejection to something staff can act on.
function describeCameraError(err) {
  switch (err.name) {
    case "NotAllowedError":
    case "PermissionDeniedError":
      return "Camera blocked - check browser settings"
    case "NotFoundError":
    case "DevicesNotFoundError":
      return "No camera found on device"
    case "NotReadableError":
    case "TrackStartError":
      return "Camera in use by another app"
    default:
      return "Camera error: " + err.name + " - " + err.message
  }
}

// Opens the camera exactly once and keeps that stream for decoding. We used
// to open a probe stream, stop it, and have ZXing reopen the camera by id,
// which iOS Safari answers with black frames or NotReadableError right after
// a first permission grant.
async function openCamera(deviceId) {
  const attempts = [{ facingMode: "environment" }, true]
  if (deviceId) attempts.unshift({ deviceId: { exact: deviceId } })
  for (let i = 0; ; i++) {
    try {
      return await navigator.mediaDevices.getUserMedia({ video: attempts[i] })
    } catch (err) {
      // Only a camera that doesn't match is worth another try; a refusal or
      // a busy camera fails the same way again.
      if (err.name !== "OverconstrainedError" || i === attempts.length - 1) throw err
    }
  }
}

// `onStatus(message, state)` reports the camera's state; `onCode(text)` fires
// for every frame a code is read from, so the caller ignores repeats.
export function createCamera({ onStatus, onCode }) {
  const video = document.getElementById("qr-video")
  const startButton = document.getElementById("start-camera-btn")
  const restartButton = document.getElementById("restart-camera-btn")
  const cameraSelect = document.getElementById("camera-select")
  const cameraSelectWrapper = document.getElementById("camera-select-wrapper")

  // The one camera stream we own, and the decode loop reading from it. Each
  // (re)start bumps the generation so a loop left over from the last stream
  // notices and exits instead of running alongside the new one.
  let cameraStream = null
  let decodeTimer = null
  let decodeGeneration = 0
  let state = "loading"

  function setStatus(message, nextState) {
    state = nextState
    onStatus(message, nextState)
  }

  function offerManualStart() {
    startButton.classList.remove("hidden")
  }

  function stop() {
    decodeGeneration++
    clearTimeout(decodeTimer)
    if (cameraStream) cameraStream.getTracks().forEach((track) => track.stop())
    cameraStream = null
    if (video) video.srcObject = null
  }

  // Device labels are only readable once we hold a stream, so this runs after
  // the camera is open.
  async function populateCameraPicker(activeId) {
    let cameras = []
    try {
      cameras = (await navigator.mediaDevices.enumerateDevices()).filter((device) => device.kind === "videoinput")
    } catch (err) {
      console.warn("Could not list cameras:", err)
    }
    cameraSelect.innerHTML = cameras
      .map((camera, i) => html`<option value="${camera.deviceId}">${camera.label || `Camera ${i + 1}`}</option>`)
      .join("")
    if (activeId) cameraSelect.value = activeId
    // Only show the picker when there's an actual choice to make
    cameraSelectWrapper.classList.toggle("hidden", cameras.length < 2)
  }

  async function start(deviceId = storedCameraId()) {
    stop() // re-entrant: restart, camera switch and tap-to-start all land here
    const generation = decodeGeneration
    startButton.classList.add("hidden")
    restartButton.classList.remove("hidden")

    if (!zxing()) {
      setStatus("Scanner library not loaded", "error")
      return
    }

    // Check for secure context (HTTPS or localhost)
    if (!window.isSecureContext) {
      setStatus("Camera requires HTTPS or localhost", "error")
      console.error("Camera access requires a secure context (HTTPS or localhost). Current URL:", window.location.href)
      return
    }

    // Check if mediaDevices API is available
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      setStatus("Camera API not available", "error")
      return
    }

    setStatus("Requesting camera access...", "loading")
    let stream
    try {
      stream = await openCamera(deviceId)
    } catch (err) {
      console.error("Camera permission error:", err.name, err.message, err)
      if (generation !== decodeGeneration) return
      setStatus(describeCameraError(err), "error")
      offerManualStart()
      return
    }

    // Restarted or navigated away while the permission prompt was up.
    if (generation !== decodeGeneration) {
      stream.getTracks().forEach((track) => track.stop())
      return
    }
    cameraStream = stream

    const track = stream.getVideoTracks()[0]
    // iOS ends the track when another app takes the camera.
    track.addEventListener("ended", () => {
      if (generation !== decodeGeneration) return
      stop()
      setStatus("Camera stopped", "error")
      offerManualStart()
    })
    populateCameraPicker(track.getSettings().deviceId)

    video.srcObject = stream
    setStatus("Starting camera...", "loading")
    try {
      await video.play()
    } catch (err) {
      if (generation !== decodeGeneration) return
      // Playback that isn't tied to a tap can be refused, e.g. in the installed PWA.
      console.error("Camera playback error:", err)
      setStatus("Tap to start camera", "error")
      offerManualStart()
      return
    }
    decodeFrames(generation)
  }

  function markReady() {
    if (state === "ready") return
    setStatus("Ready to scan", "ready")
    startButton.classList.add("hidden")
  }

  // Our own loop rather than ZXing's decodeFromVideoDevice. Its loop sizes the
  // capture canvas once, from the first frame, and stops for good on any error
  // other than "no code in this frame". Right after a camera grant iOS can
  // report a 0x0 frame, reading it throws, and the page sat on "Ready to scan"
  // with nothing decoding until staff reloaded.
  function decodeFrames(generation) {
    const ZXing = zxing()
    const reader = new ZXing.QRCodeReader()
    const canvas = document.createElement("canvas")
    const context = canvas.getContext("2d", { willReadFrequently: true })
    const startedAt = performance.now()
    let failures = 0

    ;(function tick() {
      if (generation !== decodeGeneration) return
      // Schedule first, so nothing below can end the loop.
      decodeTimer = setTimeout(tick, 100)

      if (video.readyState < video.HAVE_CURRENT_DATA || !video.videoWidth || !video.videoHeight) {
        if (performance.now() - startedAt > 8000 && state !== "error") {
          setStatus("Camera not showing a picture", "error")
          offerManualStart()
        }
        return
      }

      // The stream can change resolution or orientation mid-session.
      if (canvas.width !== video.videoWidth || canvas.height !== video.videoHeight) {
        canvas.width = video.videoWidth
        canvas.height = video.videoHeight
      }

      let text = null
      try {
        context.drawImage(video, 0, 0, canvas.width, canvas.height)
        // `true` inverts every other frame, so light-on-dark codes read too.
        const source = new ZXing.HTMLCanvasElementLuminanceSource(canvas, true)
        text = reader.decode(new ZXing.BinaryBitmap(new ZXing.HybridBinarizer(source))).getText()
      } catch (err) {
        // Every frame without a readable code lands here; that's normal.
        const expected = err instanceof ZXing.NotFoundException ||
          err instanceof ZXing.ChecksumException ||
          err instanceof ZXing.FormatException
        if (!expected) {
          failures++
          console.warn("QR decode error:", err)
          if (failures === 10) {
            setStatus("Scanner error - restart the camera", "error")
            offerManualStart()
          }
          return
        }
      }

      failures = 0
      markReady()
      if (text) onCode(text)
    })()
  }

  // Both restart on whichever camera is picked, and count as the tap iOS
  // wants before it hands over the camera.
  function restart() {
    start(cameraSelect.value || undefined)
  }
  startButton.addEventListener("click", restart)
  restartButton.addEventListener("click", restart)

  cameraSelect.addEventListener("change", function() {
    try {
      localStorage.setItem(CAMERA_STORAGE_KEY, this.value)
    } catch (_) {
      // Private browsing: the choice just isn't remembered.
    }
    start(this.value)
  })

  return { start: () => start(), stop }
}
