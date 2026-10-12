// Cloudscape-style confirmation modal for `data-turbo-confirm` in the admin
// console. Destructive actions in Cloudscape are a normal button that opens
// a confirmation dialog; this gives every existing turbo_confirm that dialog
// without touching the 50-odd call sites. Outside the console (participant,
// guardian and support pages) the browser's own confirm() is kept.
import { Turbo } from "@hotwired/turbo-rails"
import { html } from "utils/html"

function nativeConfirm(message) {
  return Promise.resolve(window.confirm(message))
}

// The action word for the confirm button: the clicked control's own label
// ("Delete event", "Remove") reads better than a generic "Confirm".
function actionLabel(element, submitter) {
  const source = submitter || element?.querySelector?.("button[type=submit], input[type=submit], button:not([type])") || element
  const text = (source?.value || source?.textContent || "").trim().replace(/\s+/g, " ")
  return text && text.length <= 40 ? text : "Confirm"
}

function consoleConfirm(message, element, submitter) {
  if (!document.documentElement.classList.contains("cs-console")) return nativeConfirm(message)

  return new Promise((resolve) => {
    const previousFocus = document.activeElement
    const overlay = document.createElement("div")
    overlay.className = "cs-modal-overlay"
    overlay.innerHTML = html`
      <div class="cs-modal" role="alertdialog" aria-modal="true" aria-labelledby="cs-confirm-title" aria-describedby="cs-confirm-body">
        <div class="cs-modal-header">
          <h2 id="cs-confirm-title">Confirm</h2>
        </div>
        <div class="cs-modal-body"><p id="cs-confirm-body" class="whitespace-pre-line">${message}</p></div>
        <div class="cs-modal-footer">
          <button type="button" class="cs-btn cs-btn-link" data-answer="false">Cancel</button>
          <button type="button" class="cs-btn cs-btn-primary" data-answer="true">${actionLabel(element, submitter)}</button>
        </div>
      </div>`.toString()

    const buttons = [...overlay.querySelectorAll("button[data-answer]")]
    const finish = (answer) => {
      document.removeEventListener("keydown", onKeydown, true)
      overlay.remove()
      previousFocus?.focus?.()
      resolve(answer)
    }

    const onKeydown = (event) => {
      if (event.key === "Escape") {
        event.preventDefault()
        finish(false)
      } else if (event.key === "Tab") {
        // Keep focus inside the dialog.
        const index = buttons.indexOf(document.activeElement)
        const next = event.shiftKey ? (index <= 0 ? buttons.length - 1 : index - 1) : (index + 1) % buttons.length
        event.preventDefault()
        buttons[next].focus()
      }
    }

    buttons.forEach((button) => button.addEventListener("click", () => finish(button.dataset.answer === "true")))
    overlay.addEventListener("mousedown", (event) => { if (event.target === overlay) finish(false) })
    document.addEventListener("keydown", onKeydown, true)
    document.body.appendChild(overlay)
    // Cancel takes focus first, so a stray Enter never confirms a destructive action.
    buttons[0].focus()
  })
}

export function startConsoleConfirm() {
  if (Turbo.config?.forms) {
    Turbo.config.forms.confirm = consoleConfirm
  } else {
    Turbo.setConfirmMethod(consoleConfirm)
  }
}
