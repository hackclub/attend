// Show/hide helper for the modals that used to do it from an inline onclick.
//
// A Content-Security-Policy without `unsafe-inline` blocks inline event
// handlers, so `onclick="document.getElementById('x').classList.add('hidden')"`
// stops working. Pages declare the same thing as data attributes instead:
//
//   <button data-hide="add-room-modal">Cancel</button>
//   <button data-show="add-room-modal">Add room</button>
//
// One delegated listener covers every page. It only ever toggles a class on an
// element looked up by id — no dispatch by name, nothing evaluated.

function toggle(event, attribute, hidden) {
  const trigger = event.target.closest(`[${attribute}]`)
  if (!trigger) return

  const target = document.getElementById(trigger.getAttribute(attribute))
  if (target) target.classList.toggle("hidden", hidden)
}

export function startToggleHidden() {
  document.addEventListener("click", (event) => {
    toggle(event, "data-hide", true)
    toggle(event, "data-show", false)
  })
}
