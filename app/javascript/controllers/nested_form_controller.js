import { Controller } from "@hotwired/stimulus"

// Handles dynamic add/remove for nested forms using a <template> with NEW_RECORD placeholder.
//
// Markup:
//   <div data-controller="nested-form">
//     <div data-nested-form-target="container"> ... existing items ... </div>
//     <template data-nested-form-target="template"> ... NEW_RECORD ... </template>
//     <button data-action="nested-form#add">Add</button>
//   </div>
//
// Each item wrapper should have data-nested-form-target="item"
// and a hidden _destroy field with data-nested-form-target="destroyField".
//
export default class extends Controller {
  static targets = ["container", "template", "item", "destroyField"]
  static values = {
    index: Number
  }

  connect() {
    if (!this.hasIndexValue) {
      this.indexValue = Date.now()
    }
  }

  add(event) {
    event.preventDefault()

    const fragment = this.templateTarget.content.cloneNode(true)
    const newIndex = this.indexValue++
    this.replaceNewRecord(fragment, newIndex)

    // Set priority for additional contacts (secondary is 1, additional start at 2)
    const priorityInput = fragment.querySelector("input[name*='[priority]']")
    if (priorityInput && !priorityInput.value) {
      const currentAdditionalCount = this.containerTarget.querySelectorAll(
        "[data-nested-form-target='item']:not(.hidden)"
      ).length
      priorityInput.value = currentAdditionalCount + 2
    }

    this.containerTarget.appendChild(fragment)
  }

  remove(event) {
    event.preventDefault()

    const item = event.target.closest("[data-nested-form-target='item']")
    if (!item) return

    const destroyField = item.querySelector("[data-nested-form-target='destroyField']")

    if (destroyField) {
      destroyField.value = "1"
      item.classList.add("hidden")
    } else {
      item.remove()
    }
  }

  replaceNewRecord(fragment, index) {
    const regexp = /NEW_RECORD/g

    fragment.querySelectorAll("[name], [id], [for]").forEach((el) => {
      if (el.name && el.name.includes("NEW_RECORD")) {
        el.name = el.name.replace(regexp, index)
      }
      if (el.id && el.id.includes("NEW_RECORD")) {
        el.id = el.id.replace(regexp, index)
      }
      if (el.htmlFor && el.htmlFor.includes("NEW_RECORD")) {
        el.htmlFor = el.htmlFor.replace(regexp, index)
      }
    })
  }
}
