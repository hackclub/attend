import { Controller } from "@hotwired/stimulus"

// Drives the custom export builder: per-category select all/none, live
// selected-column count, and dynamic filter rows whose operator and value
// inputs adapt to the selected field's type.
//
// fieldsValue: { "participant.email": { label, type, operators, enumValues } }
// operatorLabelsValue: { "contains": "contains", ... }
export default class extends Controller {
  static targets = ["filtersContainer", "filterTemplate", "count", "columnCheckbox", "searchInput"]
  static values = {
    fields: Object,
    operatorLabels: Object,
    index: Number
  }

  connect() {
    if (!this.hasIndexValue || !this.indexValue) {
      this.indexValue = Date.now()
    }
    this.updateCount()
  }

  // --- column picker ---

  selectCategory(event) {
    event.preventDefault()
    this.setCategoryChecked(event, true)
  }

  deselectCategory(event) {
    event.preventDefault()
    this.setCategoryChecked(event, false)
  }

  setCategoryChecked(event, checked) {
    const section = event.target.closest("[data-export-category]")
    section.querySelectorAll("input[type=checkbox]").forEach((cb) => (cb.checked = checked))
    this.updateCount()
  }

  updateCount() {
    if (!this.hasCountTarget) return
    const checked = this.columnCheckboxTargets.filter((cb) => cb.checked).length
    this.countTarget.textContent = `${checked} column${checked === 1 ? "" : "s"} selected`
  }

  // Live search across field labels. Categories whose title matches show all
  // their fields; categories with no hits are hidden. Open/closed state is
  // remembered while searching and restored when the query is cleared.
  search() {
    const query = this.searchInputTarget.value.trim().toLowerCase()

    this.element.querySelectorAll("[data-export-category]").forEach((section) => {
      const categoryMatch = query && section.querySelector("summary .font-medium").textContent.toLowerCase().includes(query)
      let hits = 0

      section.querySelectorAll("label").forEach((label) => {
        const hit = !query || categoryMatch || label.textContent.toLowerCase().includes(query)
        label.style.display = hit ? "" : "none"
        if (hit) hits++
      })

      if (query) {
        if (section.dataset.openBeforeSearch === undefined) {
          section.dataset.openBeforeSearch = section.open ? "1" : "0"
        }
        section.style.display = hits > 0 ? "" : "none"
        section.open = hits > 0
      } else {
        section.style.display = ""
        if (section.dataset.openBeforeSearch !== undefined) {
          section.open = section.dataset.openBeforeSearch === "1"
          delete section.dataset.openBeforeSearch
        }
      }
    })
  }

  // --- filter rows ---

  addFilter(event) {
    event.preventDefault()

    const fragment = this.filterTemplateTarget.content.cloneNode(true)
    const index = this.indexValue++
    fragment.querySelectorAll("[name]").forEach((el) => {
      el.name = el.name.replace(/NEW_RECORD/g, index)
    })

    const row = fragment.querySelector("[data-export-filter-row]")
    this.filtersContainerTarget.appendChild(fragment)

    const { field, operator } = event.currentTarget.dataset
    if (field) {
      const fieldSelect = row.querySelector("[data-export-field-select]")
      fieldSelect.value = field
      this.populateOperators(row, operator)
    }
  }

  removeFilter(event) {
    event.preventDefault()
    event.target.closest("[data-export-filter-row]").remove()
  }

  fieldChanged(event) {
    this.populateOperators(event.target.closest("[data-export-filter-row]"))
  }

  operatorChanged(event) {
    this.renderValueInput(event.target.closest("[data-export-filter-row]"))
  }

  populateOperators(row, presetOperator = null) {
    const fieldSelect = row.querySelector("[data-export-field-select]")
    const operatorSelect = row.querySelector("[data-export-operator-select]")
    const meta = this.fieldsValue[fieldSelect.value]

    operatorSelect.innerHTML = ""
    if (!meta) {
      this.renderValueInput(row)
      return
    }

    meta.operators.forEach((op) => {
      const option = document.createElement("option")
      option.value = op
      option.textContent = this.operatorLabelsValue[op] || op
      operatorSelect.appendChild(option)
    })

    if (presetOperator && meta.operators.includes(presetOperator)) {
      operatorSelect.value = presetOperator
    }

    this.renderValueInput(row)
  }

  renderValueInput(row) {
    const fieldSelect = row.querySelector("[data-export-field-select]")
    const operatorSelect = row.querySelector("[data-export-operator-select]")
    const wrapper = row.querySelector("[data-export-value-wrapper]")
    const meta = this.fieldsValue[fieldSelect.value]
    const operator = operatorSelect.value

    wrapper.innerHTML = ""
    if (!meta || ["present", "blank", "true", "false"].includes(operator)) return

    const name = fieldSelect.name.replace("[field]", "[value]")

    if (meta.type === "enum") {
      const select = document.createElement("select")
      select.name = `${name}[]`
      select.multiple = true
      select.size = Math.min(meta.enumValues.length, 5)
      select.className = "w-full rounded-md border-gray-300 text-sm"
      meta.enumValues.forEach((val) => {
        const option = document.createElement("option")
        option.value = val
        option.textContent = val.replace(/_/g, " ")
        select.appendChild(option)
      })
      wrapper.appendChild(select)
    } else {
      const input = document.createElement("input")
      input.name = name
      input.type = meta.type === "date" ? "date" : meta.type === "datetime" ? "datetime-local" : "text"
      input.className = "w-full rounded-md border-gray-300 text-sm"
      input.placeholder = "value"
      wrapper.appendChild(input)
    }
  }
}
