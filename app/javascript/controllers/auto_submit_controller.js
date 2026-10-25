import { Controller } from "@hotwired/stimulus"

// Submits the surrounding form when a filter control changes.
//   <form data-controller="auto-submit">
//     <select data-action="change->auto-submit#submit">
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
