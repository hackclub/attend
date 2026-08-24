import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["entry", "day", "search", "direction", "mode", "pickup", "group", "empty"]

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
      day.hidden = entries.every((entry) => entry.hidden)
    })

    this.emptyTarget.hidden = this.entryTargets.some((entry) => !entry.hidden)
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
}
