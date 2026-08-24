# Travel Calendar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Airport Mode with `/travel`, a day-grouped agenda for every travel mode, and generalize airport pickup scans into travel pickup resolution.

**Architecture:** A mode-neutral `TravelCalendar::JourneyBuilder` produces one shared entry shape for the admin HTML and JSON API. Scan records remain the source of truth for `collected` and `checked_in`; reversible column renames preserve existing data, and legacy Airport Mode routes and JSON keys are isolated compatibility boundaries.

**Tech Stack:** Rails 8.1, Ruby 3.4, PostgreSQL, RSpec, Hotwire/Stimulus, ERB, Tailwind CSS, Pundit/Devise authorization.

**Spec:** `docs/superpowers/specs/2026-08-24-travel-calendar-design.md`

## Global Constraints

- The canonical admin and API slug is `/travel`, not `/travel_calendar`.
- The product label remains `Travel Calendar`.
- Include `plane`, `train`, `bus`, `car`, and `other` travel for complete registrations.
- Group and display agenda times in the event timezone; place missing times under `Unscheduled`.
- Pickup precedence is `collected`, `checked_in`, `pickup_not_needed`, then `awaiting_pickup`.
- Venue check-in resolves pickup but never records collection.
- Retain legacy Airport Mode routes and JSON keys only at compatibility boundaries.
- Do not restore live flight tracking, delays, terminals, gates, or flight refresh controls.
- Keep current-event scoping and existing authorization on every read and mutation.
- Follow Attend theme tokens and WCAG 2.1 AA; never add raw color hex values to templates.

---

### Task 1: Rename airport pickup persistence and model APIs

**Files:**
- Create: `db/migrate/20260824000000_rename_airport_pickup_to_travel_pickup.rb`
- Modify: `app/models/scan_context.rb`
- Modify: `app/models/travel_leg.rb`
- Modify: `db/schema.rb`
- Test: `spec/models/scan_context_spec.rb`
- Test: `spec/models/travel_leg_spec.rb`

**Interfaces:**
- Produces: `ScanContext#is_travel_pickup?`, `TravelLeg#travel_picked_up_at`, `TravelLeg#travel_picked_up?`, `mark_travel_picked_up!(user)`, and `unmark_travel_picked_up!`.
- Preserves: existing boolean and timestamp values through reversible column renames.

- [ ] **Step 1: Write failing model specs for canonical names**

Add examples that exercise the renamed public model APIs:

```ruby
it "supports travel pickup contexts" do
  context = create(:event).scan_contexts.create!(
    name: "Central Station",
    checks_in: false,
    is_travel_pickup: true
  )

  expect(context).to be_is_travel_pickup
end

it "records and clears travel pickup on a flight leg" do
  user = create(:user)
  leg = create(:travel_leg, travel: Travel.create!(
    participant_event: create(:participant_event),
    direction: "inbound",
    mode: "plane"
  ))

  leg.mark_travel_picked_up!(user)
  expect(leg.reload.travel_picked_up_at).to be_present
  expect(leg.picked_up_by).to eq(user)

  leg.unmark_travel_picked_up!
  expect(leg.reload.travel_picked_up_at).to be_nil
  expect(leg.picked_up_by).to be_nil
end
```

- [ ] **Step 2: Run the specs and verify the missing canonical APIs fail**

Run: `bundle exec rspec spec/models/scan_context_spec.rb spec/models/travel_leg_spec.rb`

Expected: failures naming `is_travel_pickup` and `mark_travel_picked_up!`.

- [ ] **Step 3: Add the reversible migration and rename model methods**

Create the migration exactly as a column rename so production values survive:

```ruby
class RenameAirportPickupToTravelPickup < ActiveRecord::Migration[8.1]
  def change
    rename_column :scan_contexts, :is_airport, :is_travel_pickup
    rename_column :travel_legs, :airport_picked_up_at, :travel_picked_up_at
  end
end
```

Update validations and travel-leg methods to use canonical attributes:

```ruby
validates :is_travel_pickup, inclusion: { in: [ true, false ] }

def travel_picked_up?
  travel_picked_up_at.present?
end

def mark_travel_picked_up!(user)
  update!(travel_picked_up_at: Time.current, picked_up_by: user)
end

def unmark_travel_picked_up!
  update!(travel_picked_up_at: nil, picked_up_by: nil)
end
```

Run `bin/rails db:migrate` to update `db/schema.rb`. Do not edit historical migrations.

- [ ] **Step 4: Run the model specs and migration checks**

Run: `bundle exec rspec spec/models/scan_context_spec.rb spec/models/travel_leg_spec.rb`

Expected: PASS.

Run: `bin/rails db:migrate:status | tail -5`

Expected: the rename migration is `up`.

- [ ] **Step 5: Commit the persistence rename**

```bash
git add db/migrate/20260824000000_rename_airport_pickup_to_travel_pickup.rb db/schema.rb app/models/scan_context.rb app/models/travel_leg.rb spec/models/scan_context_spec.rb spec/models/travel_leg_spec.rb
git commit -m "Rename airport pickup data for travel"
```

### Task 2: Separate collection from venue check-in

**Files:**
- Create: `app/controllers/concerns/travel_pickup_markable.rb`
- Delete: `app/controllers/concerns/airport_pickup_markable.rb`
- Modify: `app/controllers/admin/scans_controller.rb`
- Modify: `app/controllers/api/v1/scans_controller.rb`
- Modify: `app/toolboxes/participant_events_toolbox.rb`
- Test: `spec/requests/api/v1/scans_spec.rb`
- Test: `spec/toolboxes/participant_events_toolbox_spec.rb`

**Interfaces:**
- Consumes: canonical model APIs from Task 1.
- Produces: private `mark_travel_pickup(participant_event, user)` used only after explicit travel pickup scans.
- Guarantees: venue check-in never writes `travel_picked_up_at`; explicit pickup scans work for every inbound mode, with the timestamp additionally recorded on a final flight leg when one exists.

- [ ] **Step 1: Write failing scan and toolbox specs**

Add request coverage for an explicit travel pickup context and a normal venue check-in:

```ruby
it "marks the final inbound flight leg for an explicit travel pickup scan" do
  pickup = event.scan_contexts.create!(name: "Station pickup", checks_in: false, is_travel_pickup: true)
  travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "plane")
  leg = create(:travel_leg, travel: travel)

  post "/api/v1/events/#{event.id}/scans",
    params: { participant_id: participant_event.id, scan_context_id: pickup.id }.to_json,
    headers: auth_headers

  expect(response).to have_http_status(:ok)
  expect(leg.reload).to be_travel_picked_up
end

it "does not mark travel pickup when checking in at the venue" do
  travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "plane")
  leg = create(:travel_leg, travel: travel)

  run_check_in(participant_event)

  expect(leg.reload).not_to be_travel_picked_up
  expect(participant_event.reload).to be_checked_in
end
```

Use the existing request authentication helpers and toolbox invocation helper already defined in those spec files rather than introducing a second test harness.

- [ ] **Step 2: Run the focused specs and verify venue check-in currently writes pickup**

Run: `bundle exec rspec spec/requests/api/v1/scans_spec.rb spec/toolboxes/participant_events_toolbox_spec.rb`

Expected: canonical attribute failures, including the venue check-in example observing a non-null pickup timestamp.

- [ ] **Step 3: Replace the concern and update all scan writers**

Create the canonical concern:

```ruby
module TravelPickupMarkable
  extend ActiveSupport::Concern

  private

  def mark_travel_pickup(participant_event, user)
    travel = participant_event.travel_inbound
    return if travel.blank?

    final_leg = travel.travel_legs.order(:position).last
    return if final_leg.blank? || final_leg.travel_picked_up?

    final_leg.mark_travel_picked_up!(user)
  end
end
```

In both scan controllers, call this method only when the new scan context is explicit pickup and it is the first scan in that context:

```ruby
if scan_context.is_travel_pickup? && first_scan_in_context
  mark_travel_pickup(participant_event, current_user)
end
```

Retain NFC badge generation under `scan_context.checks_in?`. Remove pickup marking from `ParticipantEventsToolbox#check_in`, while keeping its check-in scan and NFC behavior unchanged.

- [ ] **Step 4: Run focused scan tests**

Run: `bundle exec rspec spec/requests/api/v1/scans_spec.rb spec/toolboxes/participant_events_toolbox_spec.rb`

Expected: PASS.

- [ ] **Step 5: Commit scan semantics**

```bash
git add app/controllers/concerns app/controllers/admin/scans_controller.rb app/controllers/api/v1/scans_controller.rb app/toolboxes/participant_events_toolbox.rb spec/requests/api/v1/scans_spec.rb spec/toolboxes/participant_events_toolbox_spec.rb
git commit -m "Separate travel pickup from check-in"
```

### Task 3: Build mode-neutral travel calendar entries

**Files:**
- Create: `app/services/travel_calendar/journey_builder.rb`
- Create: `spec/services/travel_calendar/journey_builder_spec.rb`
- Modify: `app/models/travel.rb`

**Interfaces:**
- Consumes: an `Event` and its complete participant registrations.
- Produces: `TravelCalendar::JourneyBuilder.new(event:).call`, returning chronologically sorted hashes with keys `:id`, `:participant_id`, `:participant_event_id`, `:participant_name`, `:participant_preferred_name`, `:direction`, `:mode`, `:primary_time_at`, `:agenda_date`, `:route`, `:reference`, `:details`, `:pickup_state`, `:is_unaccompanied_minor`, and `:groups`.
- Defines: `Travel#calendar_time`, `Travel#calendar_route`, and `Travel#calendar_reference` as mode-aware helpers used by the builder.

- [ ] **Step 1: Write failing builder specs for every mode and ordering**

Create real travel records and assert on behavior rather than internal method calls:

```ruby
RSpec.describe TravelCalendar::JourneyBuilder do
  subject(:entries) { described_class.new(event: event).call }

  let(:event) { create(:event, timezone: "Europe/London") }

  def create_travel(mode:, direction:, **attributes)
    participant_event = create(:participant_event, event: event, status: :complete)
    Travel.create!(
      participant_event: participant_event,
      mode: mode,
      direction: direction,
      **attributes
    )
  end

  def create_plane_travel(arrival_time:)
    travel = create_travel(mode: "plane", direction: "inbound")
    create(
      :travel_leg,
      travel: travel,
      departure_time: arrival_time - 2.hours,
      arrival_time: arrival_time,
      departure_airport: "JFK",
      arrival_airport: "LHR",
      flight_code: "BA178"
    )
    travel
  end

  it "includes every travel mode in one chronological result" do
    create_travel(mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 9))
    create_travel(mode: "bus", direction: "outbound", departure_time: Time.utc(2026, 8, 24, 12))
    create_travel(mode: "car", direction: "inbound", expected_arrival_time: Time.utc(2026, 8, 25, 8))
    create_travel(mode: "other", direction: "outbound", other_details: "Collected by guardian")
    create_plane_travel(arrival_time: Time.utc(2026, 8, 24, 10))

    expect(entries.map { |entry| entry[:mode] }).to include("plane", "train", "bus", "car", "other")
    expect(entries.map { |entry| entry[:primary_time_at] }.compact).to eq(
      entries.map { |entry| entry[:primary_time_at] }.compact.sort
    )
    expect(entries.last[:agenda_date]).to be_nil
  end

  it "groups an instant by its date in the event timezone" do
    create_travel(mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 23, 30))

    expect(entries.first[:agenda_date]).to eq(Date.new(2026, 8, 25))
  end
end
```

Add examples for route/reference output, partial route data, plane travel with no legs, complete-registration filtering, and deterministic name ordering.

- [ ] **Step 2: Write failing pickup-precedence specs**

Create one registration per state, retain each participant-event ID, and assert the four outcomes:

```ruby
entries_by_registration = entries.index_by { |entry| entry[:participant_event_id] }

expect(entries_by_registration.fetch(unscanned.id)[:pickup_state]).to eq(:awaiting_pickup)
expect(entries_by_registration.fetch(dismissed.id)[:pickup_state]).to eq(:pickup_not_needed)
expect(entries_by_registration.fetch(checked_in.id)[:pickup_state]).to eq(:checked_in)
expect(entries_by_registration.fetch(collected_and_checked_in.id)[:pickup_state]).to eq(:collected)
expect(entries_by_registration.fetch(outbound.id)[:pickup_state]).to be_nil
```

- [ ] **Step 3: Run the builder spec and verify the class is missing**

Run: `bundle exec rspec spec/services/travel_calendar/journey_builder_spec.rb`

Expected: failure with `uninitialized constant TravelCalendar`.

- [ ] **Step 4: Implement the travel helpers and builder**

Use direction-aware, mode-aware helpers. The timestamp selection must be explicit:

```ruby
def calendar_time
  if plane?
    inbound? ? travel_legs.last&.arrival_time : travel_legs.first&.departure_time
  elsif car? && inbound?
    expected_arrival_time
  else
    inbound? ? arrival_time : departure_time
  end
end
```

Build pickup state from scans, not the renamed leg timestamp:

```ruby
def pickup_state(participant_event, travel)
  return nil if travel.outbound?

  contexts = participant_event.scans.filter_map(&:scan_context)
  return :collected if contexts.any?(&:is_travel_pickup?)
  return :checked_in if contexts.any?(&:checks_in?)
  return :pickup_not_needed if travel.pickup_dismissed?

  :awaiting_pickup
end
```

Implement mode-specific route and reference helpers with the existing fields:

```ruby
def calendar_route
  case mode
  when "plane"
    airports = travel_legs.flat_map { |leg| [ leg.departure_airport, leg.arrival_airport ] }.compact
    airports.each_with_object([]) { |airport, route| route << airport unless route.last == airport }.join(" → ").presence
  when "train"
    [ train_departure_station, train_arrival_station ].compact_blank.join(" → ").presence
  when "bus"
    [ bus_departure_location, bus_arrival_location ].compact_blank.join(" → ").presence
  when "car"
    origin_address.presence
  when "other"
    other_details.presence
  end
end

def calendar_reference
  return travel_legs.filter_map(&:flight_code).join(" · ").presence if plane?

  carrier.presence
end
```

Load complete registrations with participants, groups, both travels and legs, and scan contexts in bounded queries. Convert times to `event.timezone_identifier` only for `agenda_date`; preserve the original instant in `primary_time_at`. Sort scheduled entries by time and participant name, then append unscheduled entries sorted by participant name.

- [ ] **Step 5: Run the builder and model specs**

Run: `bundle exec rspec spec/services/travel_calendar/journey_builder_spec.rb spec/models/travel_leg_spec.rb`

Expected: PASS.

- [ ] **Step 6: Commit the journey builder**

```bash
git add app/services/travel_calendar/journey_builder.rb app/models/travel.rb spec/services/travel_calendar/journey_builder_spec.rb
git commit -m "Build travel calendar journeys"
```

### Task 4: Add canonical `/travel` admin and API endpoints

**Files:**
- Create: `app/controllers/admin/travel_calendar_controller.rb`
- Create: `app/controllers/api/v1/travel_calendar_controller.rb`
- Create: `app/services/travel_calendar/journey_cache.rb`
- Create: `app/views/admin/travel_calendar/show.html.erb`
- Rewrite: `app/controllers/admin/airport_mode_controller.rb` as a compatibility controller
- Rewrite: `app/controllers/api/v1/airport_mode_controller.rb` as a compatibility subclass
- Modify: `config/routes.rb`
- Modify: `app/controllers/admin/scans_controller.rb`
- Modify: `app/controllers/api/v1/scans_controller.rb`
- Modify: `app/toolboxes/participant_events_toolbox.rb`
- Create: `spec/requests/admin/travel_calendar_spec.rb`
- Create: `spec/requests/api/v1/travel_calendar_spec.rb`
- Modify: `spec/requests/api/v1/airport_mode_spec.rb`

**Interfaces:**
- Consumes: `TravelCalendar::JourneyBuilder#call` from Task 3.
- Produces: `GET /admin/events/:slug/travel`, `POST /admin/events/:slug/travel/dismiss_pickup`, and `GET /api/v1/events/:id/travel`.
- Produces: `TravelCalendar::JourneyCache.fetch(event)` and `.clear(event)` using `travel_calendar/<event-id>/journeys/v1` with a five-minute expiry.
- Preserves: legacy admin show redirects and legacy API show JSON.

- [ ] **Step 1: Write failing route and request specs**

Cover canonical output, legacy behavior, and cross-event mutation rejection:

```ruby
it "renders the canonical travel calendar" do
  sign_in admin
  get "/admin/events/#{event.slug}/travel"
  expect(response).to have_http_status(:ok)
  expect(response.body).to include("Travel Calendar")
end

it "redirects the legacy admin route and preserves filters" do
  sign_in admin
  get "/admin/events/#{event.slug}/airport_mode", params: { direction: "inbound" }
  expect(response).to redirect_to(admin_event_travel_path(event, direction: "inbound"))
end

it "rejects dismissal for another event's travel" do
  sign_in admin
  post dismiss_pickup_admin_event_travel_path(event), params: { travel_id: other_event_travel.id }
  expect(response).to have_http_status(:not_found)
end
```

For JSON, assert `entries` contains both directions, an event-timezone ISO timestamp, `agendaDate`, `mode`, route fields, and pickup state. Assert the legacy API URL returns the same entry IDs.

Add a cache invalidation example: warm `TravelCalendar::JourneyCache.fetch(event)`, create a check-in scan through the request endpoint, and expect a second fetch to report `checked_in`. Repeat with an explicit travel-pickup scan and expect `collected`.

- [ ] **Step 2: Run request specs and verify canonical routes are absent**

Run: `bundle exec rspec spec/requests/admin/travel_calendar_spec.rb spec/requests/api/v1/travel_calendar_spec.rb spec/requests/api/v1/airport_mode_spec.rb`

Expected: route recognition failures for `/travel`.

- [ ] **Step 3: Add canonical routes and controllers**

Add named canonical resources while routing the slug to the travel-calendar controllers:

```ruby
resource :travel, only: [ :show ], controller: "travel_calendar" do
  post :dismiss_pickup
end
```

Use the same path inside API event resources with `controller: "travel_calendar"`. Keep `resource :airport_mode, only: [ :show ]` for compatibility.

In the admin controller, scope dismissals through the event:

```ruby
def dismiss_pickup
  travel = Travel.joins(:participant_event)
    .where(participant_events: { event_id: current_event.id })
    .find(params[:travel_id])
  travel.dismiss_pickup!
  TravelCalendar::JourneyCache.clear(current_event)
  redirect_to admin_event_travel_path(current_event), notice: "Pickup marked as not needed."
end
```

Implement `JourneyCache.fetch(event)` with `Rails.cache.fetch` around `JourneyBuilder.new(event:).call`, and `JourneyCache.clear(event)` with `Rails.cache.delete`. Both canonical show actions read through it. Both scan controllers and the check-in toolbox clear it after creating a travel-pickup or venue-check-in scan so scan-derived status cannot remain stale. The show action assigns all entries, date groups, unscheduled entries, summary counts, groups, and filter choices. The API controller serializes the same entries with lower camel-case keys. It includes `eventTimezone`, `dates`, `entries`, and `counts` at the top level.

Make the admin legacy show action redirect with `request.query_parameters`. Make `Api::V1::AirportModeController` inherit from the canonical API controller so authorization and JSON stay identical.

Add the smallest renderable canonical view for this task; Task 5 replaces its body with the full agenda:

```erb
<h1 class="text-2xl font-bold text-(--text-strong)">Travel Calendar</h1>
<p class="text-sm text-(--text-muted)"><%= current_event.name %></p>
```

- [ ] **Step 4: Run canonical and compatibility request specs**

Run: `bundle exec rspec spec/requests/admin/travel_calendar_spec.rb spec/requests/api/v1/travel_calendar_spec.rb spec/requests/api/v1/airport_mode_spec.rb`

Expected: PASS.

- [ ] **Step 5: Commit canonical endpoints**

```bash
git add app/controllers/admin/travel_calendar_controller.rb app/controllers/admin/airport_mode_controller.rb app/controllers/api/v1/travel_calendar_controller.rb app/controllers/api/v1/airport_mode_controller.rb app/controllers/admin/scans_controller.rb app/controllers/api/v1/scans_controller.rb app/toolboxes/participant_events_toolbox.rb app/services/travel_calendar/journey_cache.rb app/views/admin/travel_calendar/show.html.erb config/routes.rb spec/requests/admin/travel_calendar_spec.rb spec/requests/api/v1/travel_calendar_spec.rb spec/requests/api/v1/airport_mode_spec.rb spec/requests/api/v1/scans_spec.rb spec/toolboxes/participant_events_toolbox_spec.rb
git commit -m "Add canonical travel calendar endpoints"
```

### Task 5: Replace the airport board with the day-grouped agenda

**Files:**
- Modify: `app/views/admin/travel_calendar/show.html.erb`
- Create: `app/views/admin/travel_calendar/_entry.html.erb`
- Create: `app/javascript/controllers/travel_calendar_filter_controller.js`
- Delete: `app/views/admin/airport_mode/show.html.erb`
- Delete: `app/views/admin/airport_mode/_journey_row.html.erb`
- Delete: `app/views/admin/airport_mode/_journey_card.html.erb`
- Delete: `app/javascript/controllers/airport_filter_controller.js`
- Delete: `app/javascript/controllers/airport_mode_controller.js`
- Delete: `app/javascript/controllers/airport_refresh_controller.js`
- Delete: `app/javascript/controllers/arrivals_tick_controller.js`
- Delete: `app/javascript/controllers/travel_detail_controller.js`
- Delete: `app/channels/airport_refresh_channel.rb`
- Create: `app/helpers/admin/travel_calendar_helper.rb`
- Delete: `app/helpers/admin/airport_mode_helper.rb`
- Test: `spec/requests/admin/travel_calendar_spec.rb`

**Interfaces:**
- Consumes: controller assignments from Task 4.
- Produces: semantic day sections, mode-neutral rows, native `<details>` expansion, and client-side filtering through `data-travel-calendar-filter-*` attributes.

- [ ] **Step 1: Extend the request spec with failing agenda assertions**

Add entries on two dates plus one unscheduled entry and assert structural output:

```ruby
expect(response.body).to include("Monday 24 August")
expect(response.body).to include("Tuesday 25 August")
expect(response.body).to include("Unscheduled")
expect(response.body).to include("Train", "Bus", "Car", "Flight", "Other")
expect(response.body).to include("Awaiting pickup", "Checked in")
expect(response.body).not_to include("Terminal", "Gate", "Refresh status")
```

Add an empty-calendar example and a travel-disabled redirect example.

- [ ] **Step 2: Run the admin request spec and verify the old Airport Mode markup fails expectations**

Run: `bundle exec rspec spec/requests/admin/travel_calendar_spec.rb`

Expected: failures for date headings, mode labels, and removed flight-tracking copy.

- [ ] **Step 3: Load the UI craft floor before editing templates**

Read the complete file:

`/Users/leo/.bb/runtime/global-skills/9c9d67931c4aec1ff20fa1948e067e0648b7c683042b5609e98aeffe748a8059/skills/impeccable/reference/craft-floor.md`

Follow it together with `PRODUCT.md` and `DESIGN.md`. This is an established Operate surface, so extend the existing clipboard visual system rather than creating a new visual world.

- [ ] **Step 4: Build the semantic agenda**

The page skeleton must use one combined agenda:

```erb
<div data-controller="travel-calendar-filter">
  <header>
    <h1 class="text-2xl font-bold text-(--text-strong)">Travel Calendar</h1>
    <p class="text-sm text-(--text-muted)"><%= current_event.name %> · times in <%= current_event.timezone_identifier %></p>
  </header>

  <nav aria-label="Travel filters" class="grid gap-2 sm:grid-cols-2 lg:grid-cols-6">
    <label>Search <input type="search" data-travel-calendar-filter-target="search" data-action="input->travel-calendar-filter#apply"></label>
    <label>Direction <select data-travel-calendar-filter-target="direction" data-action="change->travel-calendar-filter#apply"><option value="">All directions</option><option value="inbound">Inbound</option><option value="outbound">Outbound</option></select></label>
    <label>Mode <select data-travel-calendar-filter-target="mode" data-action="change->travel-calendar-filter#apply"><option value="">All modes</option><% Travel.modes.each_key do |mode| %><option value="<%= mode %>"><%= mode.titleize %></option><% end %></select></label>
    <label>Pickup <select data-travel-calendar-filter-target="pickup" data-action="change->travel-calendar-filter#apply"><option value="">All pickup states</option><option value="awaiting_pickup">Awaiting pickup</option><option value="collected">Collected</option><option value="checked_in">Checked in</option><option value="pickup_not_needed">Pickup not needed</option></select></label>
    <% if current_event.groups_enabled? %><label>Group <select data-travel-calendar-filter-target="group" data-action="change->travel-calendar-filter#apply"><option value="">All groups</option><%= options_from_collection_for_select(current_event.groups.ordered, :id, :name) %></select></label><% end %>
    <button type="button" data-action="travel-calendar-filter#reset">Clear filters</button>
  </nav>

  <% @journeys_by_date.each do |date, entries| %>
    <section data-travel-calendar-filter-target="day" aria-labelledby="travel-day-<%= date.iso8601 %>">
      <h2 id="travel-day-<%= date.iso8601 %>"><%= date.strftime("%A %-d %B") %></h2>
      <ol><%= render partial: "entry", collection: entries, as: :entry %></ol>
    </section>
  <% end %>

  <% if @unscheduled_journeys.any? %>
    <section aria-labelledby="travel-unscheduled"><h2 id="travel-unscheduled">Unscheduled</h2></section>
  <% end %>
</div>
```

Each row uses text plus state styling, not color alone. Render time, participant, direction, mode, route/reference, pickup state for inbound, groups, and a native `<details>` area containing mode-specific details, notes, and the participant travel link. Show a POST form for `pickup_not_needed` only on unresolved inbound entries.

Use semantic theme tokens such as `text-(--text-strong)`, `bg-(--bg-elev)`, and `border-(--border)` rather than raw colors. Keep Hack Club red limited to active controls and unresolved pickup attention.

- [ ] **Step 5: Implement client-side filters without hiding semantics**

Create one Stimulus controller with targets `entry`, `day`, `search`, `direction`, `mode`, `pickup`, `group`, and `empty`. Each entry carries lowercase search text, exact direction/mode/pickup values, and a space-delimited group-ID value. `apply()` computes all active predicates, toggles each entry, then hides a day only when every entry in it is hidden. `reset()` clears every control and calls `apply()`.

Move the still-used `flight_local_time` helper into `Admin::TravelCalendarHelper`; drop the obsolete bad-flight report URL helper. Remove the unused flight map, refresh channel, countdown, and dynamic flight-detail controllers listed above.

Use an input event for search and change events for selects. Do not place filtering state only in color or iconography.

- [ ] **Step 6: Run the admin request spec and asset build**

Run: `bundle exec rspec spec/requests/admin/travel_calendar_spec.rb`

Expected: PASS.

Run: `bin/rails tailwindcss:build`

Expected: exit 0 with rebuilt CSS.

- [ ] **Step 7: Commit the agenda interface**

```bash
git add app/views/admin/travel_calendar app/views/admin/airport_mode app/javascript/controllers app/channels/airport_refresh_channel.rb app/helpers/admin/travel_calendar_helper.rb app/helpers/admin/airport_mode_helper.rb spec/requests/admin/travel_calendar_spec.rb app/assets/builds/tailwind.css
git commit -m "Build the travel calendar agenda"
```

### Task 6: Rename scan-context UI and API compatibility fields

**Files:**
- Modify: `app/controllers/admin/scan_contexts_controller.rb`
- Modify: `app/controllers/admin/participants_controller.rb`
- Modify: `app/controllers/api/v1/scan_contexts_controller.rb`
- Modify: `app/controllers/api/v1/participants_controller.rb`
- Modify: `app/controllers/api/v1/scans_controller.rb`
- Modify: `app/models/event.rb`
- Modify: `app/models/scan.rb`
- Modify: `app/views/admin/scan_contexts/_form.html.erb`
- Modify: `app/views/admin/scan_contexts/index.html.erb`
- Modify: `app/views/admin/scans/scanner.html.erb`
- Modify: `app/views/admin/scans/index.html.erb`
- Modify: `app/views/admin/scans/history.html.erb`
- Modify: `app/views/admin/dashboard/show.html.erb`
- Modify: `app/views/admin/event_setup/modules.html.erb`
- Modify: `app/views/admin/events/_form.html.erb`
- Modify: `app/views/admin/participants/travel.html.erb`
- Modify: `app/views/layouts/_admin_sidebar_nav.html.erb`
- Modify: `app/javascript/controllers/command_palette_controller.js`
- Modify: `app/controllers/concerns/attend_urls.rb`
- Modify: `app/toolboxes/events_toolbox.rb`
- Modify: `app/toolboxes/links_toolbox.rb`
- Modify: `config/openapi.yml`
- Test: `spec/requests/api/v1/scan_contexts_spec.rb`
- Test: `spec/requests/api/v1/participants_spec.rb`
- Test: `spec/toolboxes/links_toolbox_spec.rb`
- Test: `spec/requests/content_security_policy_spec.rb`

**Interfaces:**
- Produces: canonical `is_travel_pickup` and `travel_picked_up_at` JSON keys.
- Preserves: deprecated `is_airport` and `airport_picked_up_at` aliases with the same values.
- Produces: canonical Attend and MCP links pointing to `/travel`.

- [ ] **Step 1: Write failing API and link expectations**

Assert both canonical and deprecated fields during the compatibility period:

```ruby
expect(context_json).to include(
  "is_travel_pickup" => true,
  "is_airport" => true
)

expect(leg_json).to include(
  "travel_picked_up_at" => leg.travel_picked_up_at.iso8601,
  "airport_picked_up_at" => leg.travel_picked_up_at.iso8601
)

expect(travel_link).to end_with("/admin/events/#{event.slug}/travel")
```

Update CSP fixture setup to use `is_travel_pickup: false`.

- [ ] **Step 2: Run compatibility specs and verify canonical fields are absent**

Run: `bundle exec rspec spec/requests/api/v1/scan_contexts_spec.rb spec/requests/api/v1/participants_spec.rb spec/toolboxes/links_toolbox_spec.rb spec/requests/content_security_policy_spec.rb`

Expected: failures for missing canonical JSON fields and the old Airport Mode link.

- [ ] **Step 3: Update permitted parameters, serializers, links, scopes, and copy**

Permit `:is_travel_pickup` in admin scan-context params. Serialize canonical and deprecated aliases explicitly at JSON boundaries:

```ruby
{
  is_travel_pickup: context.is_travel_pickup,
  is_airport: context.is_travel_pickup
}
```

Do the same for travel-leg timestamps. Rename internal scan scopes to `for_travel_pickup` and `for_travel_pickup_or_check_in`, and update their callers. Update navigation, dashboard, command palette, event-module copy, Attend URLs, toolbox links, scan-context form/list copy, and scanner/history indicators to say `Travel Calendar` or `Travel pickup` as appropriate.

Update OpenAPI tags, endpoint paths, schemas, and descriptions. Keep legacy paths and fields present with `deprecated: true`.

- [ ] **Step 4: Run API, toolbox, CSP, and model specs**

Run: `bundle exec rspec spec/requests/api/v1/scan_contexts_spec.rb spec/requests/api/v1/participants_spec.rb spec/toolboxes/links_toolbox_spec.rb spec/requests/content_security_policy_spec.rb spec/models/scan_context_spec.rb`

Expected: PASS.

- [ ] **Step 5: Search for unintended airport-domain leftovers**

Run:

```bash
rg -n "Airport Mode|is_airport|airport_picked_up_at|mark_airport_pickup|AirportPickupMarkable" app config spec
```

Expected: only deliberate deprecated API aliases, legacy route/controller names, compatibility specs, airport lookup/flight fields, and historical concepts unrelated to pickup remain. Inspect every match; replace any staff-facing Airport Mode or airport-pickup copy.

- [ ] **Step 6: Commit terminology and compatibility**

```bash
git add app config/openapi.yml spec
git commit -m "Generalize travel pickup interfaces"
```

### Task 7: Full verification and finish review

**Files:**
- Modify if findings require it: files changed in Tasks 1 through 6
- Capture: `$BB_THREAD_STORAGE/travel-calendar-desktop-light.png`
- Capture: `$BB_THREAD_STORAGE/travel-calendar-desktop-dark.png`
- Capture: `$BB_THREAD_STORAGE/travel-calendar-mobile-light.png`
- Capture: `$BB_THREAD_STORAGE/travel-calendar-mobile-dark.png`

**Interfaces:**
- Verifies: schema, behavior, authorization, API compatibility, responsive rendering, theming, accessibility, and issue acceptance criteria.

- [ ] **Step 1: Run the focused travel suite**

Run:

```bash
bundle exec rspec \
  spec/models/scan_context_spec.rb \
  spec/models/travel_leg_spec.rb \
  spec/services/travel_calendar/journey_builder_spec.rb \
  spec/requests/admin/travel_calendar_spec.rb \
  spec/requests/api/v1/travel_calendar_spec.rb \
  spec/requests/api/v1/airport_mode_spec.rb \
  spec/requests/api/v1/scans_spec.rb \
  spec/requests/api/v1/scan_contexts_spec.rb \
  spec/requests/api/v1/participants_spec.rb \
  spec/toolboxes/participant_events_toolbox_spec.rb \
  spec/toolboxes/links_toolbox_spec.rb
```

Expected: all examples pass with no warnings attributable to this change.

- [ ] **Step 2: Run the full test suite and lint**

Run: `bundle exec rspec`

Expected: PASS.

Run: `bin/rubocop`

Expected: no offenses.

Run: `git diff --check`

Expected: no whitespace errors.

- [ ] **Step 3: Start and expose the development server**

Run `bin/dev`, then expose its HTTP port with `bb connect expose <port>`. Use the returned remote URL for browser checks rather than localhost.

- [ ] **Step 4: Verify populated, empty-filter, and unscheduled states in a browser**

Sign in with the development admin account and open `/admin/events/:slug/travel`. Capture desktop and mobile screenshots in both light and dark themes to the four paths above. In the same bounded pass, verify:

- combined inbound and outbound ordering
- day headers in event time
- every transport mode
- awaiting, collected, checked-in, and pickup-not-needed states
- search and each filter
- no-results state
- native detail expansion and dismissal action
- no horizontal overflow at mobile width
- visible focus and non-color status labels

- [ ] **Step 5: Run one design detector pass and batch-fix mechanical findings**

Run:

```bash
node /Users/leo/.bb/runtime/global-skills/9c9d67931c4aec1ff20fa1948e067e0648b7c683042b5609e98aeffe748a8059/skills/impeccable/scripts/detect.mjs --json app/views/admin/travel_calendar app/javascript/controllers/travel_calendar_filter_controller.js
```

Apply mechanical fixes in one batch, rebuild Tailwind, rerun the focused admin request spec, and recapture the same four screenshots once.

- [ ] **Step 6: Run the required independent finish review**

Spawn the `impeccable_finish_reviewer` with no inherited turns. Supply the original issue request, approved design decisions, changed artifact paths, four screenshot paths, detector findings, `PRODUCT.md`, `DESIGN.md`, and the craft-floor path. Apply material fixes in one batch and request a verdict on the recaptured screenshots. Stop after the skill's two-round ceiling and report any unresolved findings exactly.

- [ ] **Step 7: Commit verified fixes**

```bash
git add app config db spec
git commit -m "Finish travel calendar"
```

If there are no changes after the earlier commits, do not create an empty commit.

- [ ] **Step 8: Record completion evidence**

Run:

```bash
git status --short
git log --oneline origin/main..HEAD
```

Expected: only the pre-existing user-owned heading edit remains unstaged, and the branch contains the design, plan, implementation, and verification commits. Report test counts, lint status, screenshot links, compatibility behavior, and the final review disposition. Do not close GitHub issue 37 until the implementation is merged or the user explicitly requests early closure.
