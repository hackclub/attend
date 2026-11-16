// Loading states that apply app-wide.
//
// 1. Page visits: Turbo's progress bar waits 500ms before it shows, so a
//    600ms page reads as a dead click for half a second. 150ms still keeps
//    instant visits from flashing it.
//
// 2. Lazy sections (LazyFrameHelper#lazy_frame): a frame whose request fails
//    would otherwise be replaced by Turbo's bare "Content missing". It gets a
//    plain message and a retry button instead, and the rest of the page keeps
//    working.
//
// 3. Form submissions: Turbo already disables the button that sent a form and
//    marks the form aria-busy. A submission still waiting after a beat also
//    gets a spinner on that button, so a slow send (releasing held
//    invitations, sending a broadcast) doesn't look like nothing happened.
//    Buttons with their own data-turbo-submits-with label are left alone.

const PROGRESS_BAR_DELAY = 150
const SUBMITTER_SPINNER_DELAY = 300

const submitterTimers = new WeakMap()

function showFrameError(frame, message) {
  const wrapper = document.createElement("div")
  wrapper.className = "lazy-frame-error"
  wrapper.setAttribute("role", "alert")

  const text = document.createElement("span")
  text.textContent = message
  wrapper.append(text)

  const retry = document.createElement("button")
  retry.type = "button"
  retry.className = frame.dataset.lazyFrameRetryClass || "underline"
  retry.textContent = "Try again"
  retry.addEventListener("click", () => {
    wrapper.remove()
    frame.reload()
  })
  wrapper.append(retry)

  frame.replaceChildren(wrapper)
}

function isLazyFrame(element) {
  return element?.localName === "turbo-frame" && element.classList.contains("lazy-frame")
}

function startSubmitterSpinner(event) {
  const submitter = event.detail.formSubmission?.submitter
  if (!submitter || submitter.hasAttribute("data-turbo-submits-with")) return

  const timer = window.setTimeout(() => {
    // The spinner is drawn in the button's own text colour, which is about to
    // go transparent so the label doesn't show through it.
    submitter.style.setProperty("--loading-spinner-color", getComputedStyle(submitter).color)
    submitter.setAttribute("data-loading-submitter", "")
  }, SUBMITTER_SPINNER_DELAY)
  submitterTimers.set(submitter, timer)
}

function stopSubmitterSpinner(event) {
  const submitter = event.detail.formSubmission?.submitter
  if (!submitter) return

  window.clearTimeout(submitterTimers.get(submitter))
  submitterTimers.delete(submitter)
  submitter.removeAttribute("data-loading-submitter")
  submitter.style.removeProperty("--loading-spinner-color")
}

export function startLoadingStates() {
  if (window.Turbo?.config?.drive) window.Turbo.config.drive.progressBarDelay = PROGRESS_BAR_DELAY

  // The server answered, but not with this frame: an error page, or a
  // redirect to sign-in after the session lapsed.
  document.addEventListener("turbo:frame-missing", (event) => {
    if (!isLazyFrame(event.target)) return

    const { response } = event.detail
    // Signed out mid-session: follow the redirect as a full visit, the same as
    // any other link would.
    if (response.redirected && response.ok) {
      event.preventDefault()
      event.detail.visit(response)
      return
    }

    event.preventDefault()
    showFrameError(event.target, "This section couldn't be loaded.")
  })

  // The request never got an answer (offline, timed out).
  document.addEventListener("turbo:fetch-request-error", (event) => {
    if (!isLazyFrame(event.target)) return

    showFrameError(event.target, "This section couldn't be loaded. Check your connection.")
  })

  // A link to an anchor inside a lazy section (the series events table's
  // pagination goes to #series-events) arrives before the anchor exists, so
  // the browser has nothing to scroll to. Scroll once the section is in.
  document.addEventListener("turbo:frame-load", (event) => {
    if (!isLazyFrame(event.target) || !window.location.hash) return

    let anchor
    try {
      anchor = event.target.querySelector(decodeURIComponent(window.location.hash))
    } catch {
      return
    }
    anchor?.scrollIntoView()
  })

  document.addEventListener("turbo:submit-start", startSubmitterSpinner)
  document.addEventListener("turbo:submit-end", stopSubmitterSpinner)
}
