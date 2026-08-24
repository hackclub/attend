import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const controllerUrl = new URL("../../app/javascript/controllers/travel_calendar_filter_controller.js", import.meta.url)
const controllerSource = await readFile(controllerUrl, "utf8")
const runnableSource = controllerSource.replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
const { default: TravelCalendarFilterController } = await import(`data:text/javascript;base64,${Buffer.from(runnableSource).toString("base64")}`)

function entry({ search, direction, mode, pickup, groups }) {
  return {
    dataset: {
      travelCalendarFilterSearchValue: search,
      travelCalendarFilterDirectionValue: direction,
      travelCalendarFilterModeValue: mode,
      travelCalendarFilterPickupValue: pickup,
      travelCalendarFilterGroupsValue: groups
    },
    hidden: false
  }
}

function day(entries) {
  return {
    hidden: false,
    contains(candidate) {
      return entries.includes(candidate)
    }
  }
}

function buildController() {
  const matching = entry({
    search: "avery midnight duty phone oakland amtrak",
    direction: "inbound",
    mode: "train",
    pickup: "awaiting_pickup",
    groups: "group-one group-two"
  })
  const other = entry({
    search: "blake airport shuttle",
    direction: "outbound",
    mode: "bus",
    pickup: "",
    groups: "group-three"
  })
  const controller = new TravelCalendarFilterController()
  let focused = false

  Object.assign(controller, {
    entryTargets: [matching, other],
    dayTargets: [day([matching]), day([other])],
    searchTarget: { value: "midnight duty" },
    directionTarget: { value: "inbound" },
    modeTarget: { value: "train" },
    pickupTarget: { value: "awaiting_pickup" },
    groupTarget: { value: "group-two" },
    hasGroupTarget: true,
    emptyTarget: { hidden: true }
  })
  controller.searchTarget.focus = () => { focused = true }

  return { controller, matching, other, focused: () => focused }
}

test("apply combines every active predicate and hides empty days", () => {
  const { controller, matching, other } = buildController()

  controller.apply()

  assert.equal(matching.hidden, false)
  assert.equal(other.hidden, true)
  assert.equal(controller.dayTargets[0].hidden, false)
  assert.equal(controller.dayTargets[1].hidden, true)
  assert.equal(controller.emptyTarget.hidden, true)

  controller.searchTarget.value = "no matching journey"
  controller.apply()

  assert.equal(matching.hidden, true)
  assert.equal(controller.dayTargets[0].hidden, true)
  assert.equal(controller.emptyTarget.hidden, false)
})

test("reset clears every control, restores entries, and returns focus to search", () => {
  const { controller, matching, other, focused } = buildController()

  controller.apply()
  controller.reset()

  assert.deepEqual([
    controller.searchTarget.value,
    controller.directionTarget.value,
    controller.modeTarget.value,
    controller.pickupTarget.value,
    controller.groupTarget.value
  ], ["", "", "", "", ""])
  assert.equal(matching.hidden, false)
  assert.equal(other.hidden, false)
  assert.equal(focused(), true)
})
