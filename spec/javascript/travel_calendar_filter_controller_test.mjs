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
  const count = { textContent: `${entries.length} ${entries.length === 1 ? "journey" : "journeys"}` }

  return {
    count,
    hidden: false,
    contains(candidate) {
      return entries.includes(candidate)
    },
    querySelector(selector) {
      assert.equal(selector, "[data-travel-calendar-filter-target~='count']")
      return count
    }
  }
}

function trackedEmptyState(initiallyHidden = true) {
  let hidden = initiallyHidden
  let writes = 0

  return {
    get hidden() {
      return hidden
    },
    set hidden(value) {
      hidden = value
      writes += 1
    },
    writes() {
      return writes
    }
  }
}

function select(value, availableValues) {
  return {
    value,
    options: availableValues.map((optionValue) => ({ value: optionValue }))
  }
}

function buildController() {
  const matching = entry({
    search: "alex avery midnight duty phone oakland ba178",
    direction: "inbound",
    mode: "plane",
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
  const later = entry({
    search: "casey station",
    direction: "outbound",
    mode: "train",
    pickup: "",
    groups: "group-two"
  })
  const controller = new TravelCalendarFilterController()
  let focused = false

  Object.assign(controller, {
    entryTargets: [matching, other, later],
    dayTargets: [day([matching, other]), day([later])],
    searchTarget: { value: "midnight duty" },
    directionTarget: select("inbound", ["", "inbound", "outbound"]),
    modeTarget: select("plane", ["", "plane", "train", "bus"]),
    pickupTarget: select("awaiting_pickup", ["", "awaiting_pickup", "collected", "checked_in", "pickup_not_needed"]),
    groupTarget: select("group-two", ["", "group-one", "group-two", "group-three"]),
    hasSearchTarget: true,
    hasDirectionTarget: true,
    hasModeTarget: true,
    hasPickupTarget: true,
    hasGroupTarget: true,
    hasEmptyTarget: true,
    emptyTarget: trackedEmptyState()
  })
  controller.searchTarget.focus = () => { focused = true }

  return { controller, matching, other, later, focused: () => focused }
}

test("connect initializes canonical query filters and applies them immediately", () => {
  const { controller, matching, other, later } = buildController()
  controller.searchTarget.value = ""
  controller.directionTarget.value = ""
  controller.modeTarget.value = ""
  controller.pickupTarget.value = ""
  controller.groupTarget.value = ""
  globalThis.window = {
    location: {
      search: "?direction=inbound&mode=plane&group=group-two&pickup=awaiting_pickup&search=alex"
    }
  }

  controller.connect()

  assert.deepEqual([
    controller.searchTarget.value,
    controller.directionTarget.value,
    controller.modeTarget.value,
    controller.pickupTarget.value,
    controller.groupTarget.value
  ], ["alex", "inbound", "plane", "awaiting_pickup", "group-two"])
  assert.equal(matching.hidden, false)
  assert.equal(other.hidden, true)
  assert.equal(later.hidden, true)
  assert.equal(controller.dayTargets[0].hidden, false)
  assert.equal(controller.dayTargets[0].count.textContent, "1 journey")
  assert.equal(controller.dayTargets[1].hidden, true)
  assert.equal(controller.dayTargets[1].count.textContent, "0 journeys")
  assert.equal(controller.emptyTarget.hidden, true)
})

test("connect ignores unavailable select values and exposes query no-results state", () => {
  const { controller } = buildController()
  controller.searchTarget.value = ""
  controller.directionTarget.value = ""
  controller.modeTarget.value = ""
  controller.pickupTarget.value = ""
  controller.groupTarget.value = ""
  globalThis.window = {
    location: {
      search: "?direction=sideways&mode=rocket&group=missing&pickup=unknown&search=no-such-person"
    }
  }

  controller.connect()

  assert.deepEqual([
    controller.directionTarget.value,
    controller.modeTarget.value,
    controller.pickupTarget.value,
    controller.groupTarget.value
  ], ["", "", "", ""])
  assert.equal(controller.searchTarget.value, "no-such-person")
  assert.equal(controller.dayTargets[0].hidden, true)
  assert.equal(controller.dayTargets[0].count.textContent, "0 journeys")
  assert.equal(controller.dayTargets[1].hidden, true)
  assert.equal(controller.dayTargets[1].count.textContent, "0 journeys")
  assert.equal(controller.emptyTarget.hidden, false)
})

test("connect is inert on an empty calendar without filter targets", () => {
  const controller = new TravelCalendarFilterController()
  let applyCalls = 0
  Object.assign(controller, {
    hasSearchTarget: false,
    apply() {
      applyCalls += 1
    }
  })
  globalThis.window = { location: { search: "?direction=inbound&search=alex" } }

  assert.doesNotThrow(() => controller.connect())
  assert.equal(applyCalls, 0)
})

test("apply combines every active predicate and hides empty days", () => {
  const { controller, matching, other } = buildController()

  controller.apply()

  assert.equal(matching.hidden, false)
  assert.equal(other.hidden, true)
  assert.equal(controller.dayTargets[0].hidden, false)
  assert.equal(controller.dayTargets[1].hidden, true)
  assert.equal(controller.dayTargets[0].count.textContent, "1 journey")
  assert.equal(controller.dayTargets[1].count.textContent, "0 journeys")
  assert.equal(controller.emptyTarget.hidden, true)

  controller.searchTarget.value = "no matching journey"
  controller.apply()

  assert.equal(matching.hidden, true)
  assert.equal(controller.dayTargets[0].hidden, true)
  assert.equal(controller.emptyTarget.hidden, false)
})

test("apply exposes no-results once until the result state changes", () => {
  const { controller } = buildController()
  controller.searchTarget.value = "no matching journey"

  controller.apply()
  controller.apply()

  assert.equal(controller.emptyTarget.hidden, false)
  assert.equal(controller.emptyTarget.writes(), 1)

  controller.searchTarget.value = ""
  controller.apply()

  assert.equal(controller.emptyTarget.hidden, true)
  assert.equal(controller.emptyTarget.writes(), 2)
})

test("reset clears every control, restores entries, and returns focus to search", () => {
  const { controller, matching, other, later, focused } = buildController()

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
  assert.equal(later.hidden, false)
  assert.equal(controller.dayTargets[0].count.textContent, "2 journeys")
  assert.equal(controller.dayTargets[1].count.textContent, "1 journey")
  assert.equal(focused(), true)
})
