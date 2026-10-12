import { Controller } from "@hotwired/stimulus"

// Cloudscape-style expandable row groups in a table: a header row's caret
// button shows or hides the rows grouped under it (e.g. a series' events on
// the admin events table). Put the controller on the table; give the button
//   data-action="cs-row-group#toggle" data-cs-row-group-group-param="<id>"
// and each grouped row data-cs-row-group-target="row" data-group="<id>".
// The server renders the initial state, so the rows' `hidden` attribute and
// the button's aria-expanded must agree.
export default class extends Controller {
  static targets = ["row"]

  toggle({ currentTarget, params }) {
    const expanded = currentTarget.getAttribute("aria-expanded") !== "true"
    currentTarget.setAttribute("aria-expanded", String(expanded))
    this.rowTargets
      .filter((row) => row.dataset.group === String(params.group))
      .forEach((row) => { row.hidden = !expanded })
  }
}
