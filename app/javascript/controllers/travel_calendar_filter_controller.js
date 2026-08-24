import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["entry", "day", "count", "search", "direction", "mode", "pickup", "group", "empty"]

  connect() {
    const query = new URLSearchParams(window.location.search)

    this.searchTarget.value = query.get("search") || ""
    this.setSelectFromQuery(this.directionTarget, query, "direction")
    this.setSelectFromQuery(this.modeTarget, query, "mode")
    this.setSelectFromQuery(this.pickupTarget, query, "pickup")
    if (this.hasGroupTarget) this.setSelectFromQuery(this.groupTarget, query, "group")

    this.apply()
  }

  apply() {
    const search = this.searchTarget.value.trim().toLowerCase()
    const direction = this.directionTarget.value
    const mode = this.modeTarget.value
    const pickup = this.pickupTarget.value
    const group = this.hasGroupTarget ? this.groupTarget.value : ""

    this.entryTargets.forEach((entry) => {
      const groupIds = entry.dataset.travelCalendarFilterGroupsValue.split(" ").filter(Boolean)
      const matches =
        (!search || entry.dataset.travelCalendarFilterSearchValue.includes(search)) &&
        (!direction || entry.dataset.travelCalendarFilterDirectionValue === direction) &&
        (!mode || entry.dataset.travelCalendarFilterModeValue === mode) &&
        (!pickup || entry.dataset.travelCalendarFilterPickupValue === pickup) &&
        (!group || groupIds.includes(group))

      entry.hidden = !matches
    })

    this.dayTargets.forEach((day) => {
      const entries = this.entryTargets.filter((entry) => day.contains(entry))
      const visibleCount = entries.filter((entry) => !entry.hidden).length
      const count = day.querySelector("[data-travel-calendar-filter-target~='count']")

      count.textContent = `${visibleCount} ${visibleCount === 1 ? "journey" : "journeys"}`
      day.hidden = visibleCount === 0
    })

    const shouldHideEmptyState = this.entryTargets.some((entry) => !entry.hidden)
    if (this.emptyTarget.hidden !== shouldHideEmptyState) this.emptyTarget.hidden = shouldHideEmptyState
  }

  reset() {
    this.searchTarget.value = ""
    this.directionTarget.value = ""
    this.modeTarget.value = ""
    this.pickupTarget.value = ""
    if (this.hasGroupTarget) this.groupTarget.value = ""

    this.apply()
    this.searchTarget.focus()
  }

  setSelectFromQuery(select, query, key) {
    const requestedValue = query.get(key) || ""
    const available = Array.from(select.options).some((option) => option.value === requestedValue)

    select.value = available ? requestedValue : ""
  }
}
