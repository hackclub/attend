import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "filterPanel",
    "filterList",
    "sortDropdown",
    "groupDropdown",
    "columnToggle",
    "table",
    "searchInput",
    "filterTemplate"
  ]

  static values = {
    baseUrl: String,
    filters: { type: Array, default: [] },
    sort: { type: String, default: "legal_last_name" },
    direction: { type: String, default: "asc" },
    groupBy: { type: String, default: "" },
    hiddenColumns: { type: Array, default: [] },
    filterLogic: { type: String, default: "and" },
    scanContexts: { type: Array, default: [] },
    groups: { type: Array, default: [] }
  }

  connect() {
    this.loadStateFromUrl()
    this.applyColumnVisibility()
  }

  loadStateFromUrl() {
    const url = new URL(window.location.href)
    
    if (url.searchParams.get("sort")) {
      this.sortValue = url.searchParams.get("sort")
    }
    if (url.searchParams.get("direction")) {
      this.directionValue = url.searchParams.get("direction")
    }
    if (url.searchParams.get("group_by")) {
      this.groupByValue = url.searchParams.get("group_by")
    }
    if (url.searchParams.get("filter_logic")) {
      this.filterLogicValue = url.searchParams.get("filter_logic")
    }
  }

  setFilterLogic(event) {
    this.filterLogicValue = event.target.value
  }

  toggleFilterPanel() {
    this.filterPanelTarget.classList.toggle("hidden")
  }

  addFilter() {
    const filterHtml = `
      <div class="flex items-center gap-2 p-2 bg-gray-50 rounded-lg filter-row" data-data-table-target="filterRow">
        <select class="border border-gray-300 rounded px-2 py-1 text-sm" data-field data-action="change->data-table#updateFilterOptions">
          <option value="">Select field...</option>
          <optgroup label="Basic Info">
            <option value="legal_first_name">First Name</option>
            <option value="legal_last_name">Last Name</option>
            <option value="preferred_name">Preferred Name</option>
            <option value="email">Email</option>
            <option value="pronouns">Pronouns</option>
            <option value="tshirt_size">T-Shirt Size</option>
          </optgroup>
          <optgroup label="Status">
            <option value="status">Status</option>
            <option value="onboarding_complete">Onboarding Complete</option>
            <option value="waiver_signed">Waiver Signed</option>
          </optgroup>
          <optgroup label="Demographics">
            <option value="age">Age</option>
            <option value="is_minor">Is Minor</option>
          </optgroup>
          <optgroup label="Travel">
            <option value="travel_mode">Travel Mode</option>
          </optgroup>
          <optgroup label="Health & Safety">
            <option value="has_anaphylaxis">Anaphylaxis Risk</option>
            <option value="high_support">High Support</option>
            <option value="freedom_waiver_granted">Freedom Waiver</option>
          </optgroup>
          <optgroup label="Check-In">
            <option value="scan_context">Scan Context</option>
          </optgroup>
          ${this.groupsValue.length ? `<optgroup label="Groups"><option value="group">Group</option></optgroup>` : ""}
        </select>
        <select class="border border-gray-300 rounded px-2 py-1 text-sm" data-operator>
          <option value="is">is</option>
          <option value="is_not">is not</option>
          <option value="contains">contains</option>
        </select>
        <div data-value-container>
          <input type="text" class="border border-gray-300 rounded px-2 py-1 text-sm w-40" placeholder="Value..." data-value>
        </div>
        <button type="button" class="text-red-500 hover:text-red-700 p-1" data-action="click->data-table#removeFilter">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
          </svg>
        </button>
      </div>
    `
    this.filterListTarget.insertAdjacentHTML("beforeend", filterHtml)
  }

  updateFilterOptions(event) {
    const row = event.target.closest(".filter-row")
    const field = event.target.value
    const operatorSelect = row.querySelector("[data-operator]")
    const valueContainer = row.querySelector("[data-value-container]")
    
    const booleanFields = ["onboarding_complete", "waiver_signed", "is_minor", "has_anaphylaxis", "high_support", "freedom_waiver_granted"]
    const selectFields = {
      status: [
        ["awaiting_participant", "Awaiting Participant"],
        ["awaiting_parent", "Awaiting Parent"],
        ["complete", "Complete"],
        ["withdrawn", "Withdrawn"],
        ["rejected", "Rejected"]
      ],
      travel_mode: [
        ["plane", "Plane"],
        ["train", "Train"],
        ["car", "Car"],
        ["bus", "Bus"],
        ["other", "Other"]
      ],
      tshirt_size: [
        ["xs", "XS"],
        ["s", "S"],
        ["m", "M"],
        ["l", "L"],
        ["xl", "XL"],
        ["xxl", "XXL"]
      ]
    }
    
    if (field === "group") {
      operatorSelect.innerHTML = '<option value="is">is</option><option value="is_not">is not</option><option value="is_empty">has no group</option><option value="is_not_empty">has any group</option>'

      const select = document.createElement("select")
      select.className = "border border-gray-300 rounded px-2 py-1 text-sm"
      select.setAttribute("data-value", "")
      this.groupsValue.forEach((g) => {
        const option = document.createElement("option")
        option.value = g.id
        option.textContent = g.name
        select.appendChild(option)
      })
      valueContainer.replaceChildren(select)
    } else if (field === "scan_context") {
      operatorSelect.innerHTML = '<option value="scanned_in">scanned in at</option><option value="not_scanned_in">not scanned in at</option>'

      const select = document.createElement("select")
      select.className = "border border-gray-300 rounded px-2 py-1 text-sm"
      select.setAttribute("data-value", "")

      this.scanContextsValue.forEach((sc) => {
        const option = document.createElement("option")
        option.value = sc.id
        option.textContent = sc.name
        select.appendChild(option)
      })

      valueContainer.replaceChildren(select)
    } else if (booleanFields.includes(field)) {
      operatorSelect.innerHTML = '<option value="is">is</option>'
      valueContainer.innerHTML = `
        <select class="border border-gray-300 rounded px-2 py-1 text-sm" data-value>
          <option value="true">Yes</option>
          <option value="false">No</option>
        </select>
      `
    } else if (selectFields[field]) {
      operatorSelect.innerHTML = '<option value="is">is</option><option value="is_not">is not</option>'
      const options = selectFields[field].map(([val, label]) => `<option value="${val}">${label}</option>`).join("")
      valueContainer.innerHTML = `
        <select class="border border-gray-300 rounded px-2 py-1 text-sm" data-value>
          ${options}
        </select>
      `
    } else if (field === "age") {
      operatorSelect.innerHTML = `
        <option value="equals">equals</option>
        <option value="greater_than">greater than</option>
        <option value="less_than">less than</option>
      `
      valueContainer.innerHTML = '<input type="number" class="border border-gray-300 rounded px-2 py-1 text-sm w-20" placeholder="Age" data-value>'
    } else {
      operatorSelect.innerHTML = `
        <option value="contains">contains</option>
        <option value="equals">equals</option>
        <option value="starts_with">starts with</option>
        <option value="is_empty">is empty</option>
        <option value="is_not_empty">is not empty</option>
      `
      valueContainer.innerHTML = '<input type="text" class="border border-gray-300 rounded px-2 py-1 text-sm w-40" placeholder="Value..." data-value>'
    }
  }

  removeFilter(event) {
    event.target.closest(".filter-row").remove()
  }

  applyFilters() {
    const url = new URL(this.baseUrlValue, window.location.origin)
    
    const filterRows = this.filterListTarget.querySelectorAll(".filter-row")
    filterRows.forEach((row, index) => {
      const field = row.querySelector("[data-field]").value
      const operator = row.querySelector("[data-operator]").value
      const value = row.querySelector("[data-value]").value
      
      if (field && value) {
        url.searchParams.append(`filters[${index}][field]`, field)
        url.searchParams.append(`filters[${index}][operator]`, operator)
        url.searchParams.append(`filters[${index}][value]`, value)
      }
    })

    if (this.sortValue) {
      url.searchParams.set("sort", this.sortValue)
      url.searchParams.set("direction", this.directionValue)
    }

    if (this.groupByValue) {
      url.searchParams.set("group_by", this.groupByValue)
    }

    if (this.filterLogicValue && this.filterLogicValue !== "and") {
      url.searchParams.set("filter_logic", this.filterLogicValue)
    }

    window.location.href = url.toString()
  }

  clearFilters() {
    this.filterListTarget.innerHTML = ""
    this.filtersValue = []
    
    const url = new URL(this.baseUrlValue, window.location.origin)
    if (this.sortValue) {
      url.searchParams.set("sort", this.sortValue)
      url.searchParams.set("direction", this.directionValue)
    }
    window.location.href = url.toString()
  }

  sort(event) {
    const field = event.currentTarget.dataset.sortField
    
    if (this.sortValue === field) {
      this.directionValue = this.directionValue === "asc" ? "desc" : "asc"
    } else {
      this.sortValue = field
      this.directionValue = "asc"
    }
    
    this.applyFilters()
  }

  groupBy(event) {
    this.groupByValue = event.currentTarget.dataset.value || event.target.value
    this.applyFilters()
  }

  clearGrouping() {
    this.groupByValue = "none"
    this.applyFilters()
  }

  toggleColumn(event) {
    const column = event.target.dataset.column
    const isChecked = event.target.checked
    
    if (isChecked) {
      this.hiddenColumnsValue = this.hiddenColumnsValue.filter(c => c !== column)
    } else {
      this.hiddenColumnsValue = [...this.hiddenColumnsValue, column]
    }
    
    this.applyColumnVisibility()
    this.saveColumnPreferences()
  }

  applyColumnVisibility() {
    this.hiddenColumnsValue.forEach(column => {
      const cells = this.tableTarget.querySelectorAll(`[data-column="${column}"]`)
      cells.forEach(cell => cell.classList.add("hidden"))
    })
    
    const allColumns = this.tableTarget.querySelectorAll("[data-column]")
    allColumns.forEach(cell => {
      const column = cell.dataset.column
      if (!this.hiddenColumnsValue.includes(column)) {
        cell.classList.remove("hidden")
      }
    })
  }

  saveColumnPreferences() {
    localStorage.setItem("participantTableColumns", JSON.stringify(this.hiddenColumnsValue))
  }

  search(event) {
    const query = event.target.value.toLowerCase()
    const rows = this.tableTarget.querySelectorAll("tbody tr[data-searchable]")
    
    rows.forEach(row => {
      const text = row.textContent.toLowerCase()
      row.classList.toggle("hidden", !text.includes(query))
    })
  }

  toggleSortDropdown() {
    this.sortDropdownTarget.classList.toggle("hidden")
  }

  toggleGroupDropdown() {
    this.groupDropdownTarget.classList.toggle("hidden")
  }

  toggleColumnToggle() {
    this.columnToggleTarget.classList.toggle("hidden")
  }

  selectRow(event) {
    if (event.target.type === "checkbox") {
      const row = event.target.closest("tr")
      row.classList.toggle("bg-blue-50", event.target.checked)
    }
  }

  selectAll(event) {
    const checkboxes = this.tableTarget.querySelectorAll("tbody input[type='checkbox']")
    checkboxes.forEach(checkbox => {
      checkbox.checked = event.target.checked
      const row = checkbox.closest("tr")
      row.classList.toggle("bg-blue-50", event.target.checked)
    })
  }

  collapseGroup(event) {
    const groupId = event.currentTarget.dataset.groupId
    const groupRows = this.tableTarget.querySelectorAll(`tr[data-group="${groupId}"]`)
    const icon = event.currentTarget.querySelector("svg")
    
    groupRows.forEach(row => row.classList.toggle("hidden"))
    icon.classList.toggle("rotate-90")
  }
}
