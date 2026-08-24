# Travel Calendar Design

## Goal

Replace Airport Mode with a day-grouped chronological travel agenda that gives event staff one operational view of every participant's inbound and outbound travel, regardless of transport mode. Replace airport-specific pickup contexts with travel pickup contexts while keeping venue check-in and transport collection as distinct facts.

## Scope

This change covers the admin travel dashboard, the corresponding JSON API, scan-context terminology and behavior, pickup state, navigation, and compatibility for existing Airport Mode consumers.

It does not redesign participant travel collection, restore live flight tracking, add external train or bus tracking, or change which participant registrations are eligible for staff travel views.

## Domain Model

### Travel calendar entries

Each complete participant registration may contribute one inbound and one outbound entry. Entries support all existing `Travel` modes: `plane`, `train`, `bus`, `car`, and `other`.

The canonical agenda timestamp is:

- inbound plane: final flight leg arrival time
- outbound plane: first flight leg departure time
- inbound train or bus: travel arrival time
- outbound train or bus: travel departure time
- inbound car: expected arrival time
- outbound car: travel departure time when present
- other: the available direction-appropriate travel time when present

Entries with no usable timestamp remain visible in an `Unscheduled` group after all dated groups. Dated entries are grouped and displayed in the event timezone. Within each group, entries sort chronologically and then by participant display name for deterministic ordering.

Mode-specific route summaries use existing fields:

- plane: airport route and flight code from travel legs
- train: departure and arrival stations
- bus: departure and arrival locations
- car: origin or destination address
- other: supplied travel details

Partial route data is rendered as available and never prevents an entry from appearing.

### Pickup resolution

Pickup state applies to inbound travel only. It has four operational outcomes:

- `awaiting_pickup`: no travel pickup scan, venue check-in scan, or manual dismissal exists
- `collected`: the participant has a scan in a context explicitly marked as travel pickup
- `checked_in`: the participant has a venue check-in scan and no travel pickup scan; the participant no longer needs collection
- `pickup_not_needed`: staff manually dismissed pickup and neither scan-derived state takes precedence

Precedence is `collected`, then `checked_in`, then `pickup_not_needed`, then `awaiting_pickup`. The scan records remain the source of truth for collected and checked-in states. A venue check-in does not write a travel pickup timestamp.

The manual dismissal timestamp remains on `Travel` because it is a decision about one inbound journey rather than a scan event.

### Naming migration

Rename airport-specific persistence and Ruby APIs:

- `scan_contexts.is_airport` to `scan_contexts.is_travel_pickup`
- `travel_legs.airport_picked_up_at` to `travel_legs.travel_picked_up_at`
- `AirportPickupMarkable` to `TravelPickupMarkable`
- Airport Mode controllers, helpers, JavaScript controllers, cache keys, views, and route helpers to Travel Calendar terminology

Existing boolean and timestamp values are preserved by column-renaming migrations. Future travel pickup timestamps are written only for explicit travel pickup contexts. Historical pickup state displayed by the calendar is derived primarily from scans, which avoids treating historical venue check-ins as collections.

## Architecture

A focused journey builder will convert `Travel`, participant, group, and scan records into mode-neutral calendar entries. Both the admin HTML controller and API controller consume this builder so ordering, mode summaries, timestamps, and pickup state cannot drift between interfaces.

The builder returns presentation-ready values without producing HTML or camel-cased API payloads. The controllers remain responsible for authorization, filtering, cache access, HTML assignments, and JSON serialization.

The admin controller loads complete registrations with participants, groups, inbound and outbound travel, flight legs, and scan contexts in bounded queries. It produces one combined list by default, with optional direction, mode, group, pickup-state, and search filters. The cache namespace changes from `airport_mode` to `travel_calendar` and is invalidated after travel pickup scans and manual dismissal changes.

The API exposes the same combined entry model and canonical terminology. Existing endpoint authorization rules remain unchanged.

## Routes and Compatibility

Canonical routes use `travel_calendar`:

- admin HTML: `/admin/events/:event_slug/travel_calendar`
- API JSON: `/api/v1/events/:event_id/travel_calendar`

Existing `airport_mode` web routes redirect to the canonical admin page while retaining relevant query parameters. Existing `airport_mode` API routes invoke the canonical endpoint behavior directly so API clients continue receiving JSON rather than redirects.

Canonical API payloads use `is_travel_pickup` and `travel_picked_up_at`. During the compatibility period, scan-context and travel-leg payloads also include `is_airport` and `airport_picked_up_at` aliases with identical values. OpenAPI documentation marks legacy routes and fields deprecated.

Internal code and newly generated links use only canonical names. Compatibility aliases are isolated at route and serialization boundaries rather than propagated through the domain model.

## Admin Interface

The surface remains a dense staff operations screen inside Attend's established design system. It uses semantic theme tokens, hairline borders, system typography, and Hack Club red only for active controls and unresolved pickup attention.

The page contains:

1. A `Travel Calendar` heading and event context.
2. A sticky control bar with search and filters for direction, mode, group, and pickup state.
3. One chronological agenda containing both inbound and outbound entries.
4. Day sections labelled in event-local time, followed by an `Unscheduled` section when necessary.

Each agenda row shows:

- event-local time or `Time not provided`
- participant name, headshot when available, and group badges
- inbound or outbound direction
- transport mode
- mode-specific route or details
- flight code for plane travel, without live-flight status language
- pickup state for inbound travel

Awaiting pickup is the strongest row state. Collected, checked in, and pickup not needed are quieter resolved states. Outbound entries do not show pickup state. Rows expand into the existing travel detail interaction and link to the participant record.

The interface removes live flight status, delay, progress, terminal, gate, airport grouping, and flight-refresh concepts. Search covers participant names, route text, mode, carrier or flight code, and free-form travel details.

Empty states distinguish no travel records from a filter with no matches. Missing or partial data remains legible. Controls have visible labels, keyboard focus, and non-color state indicators. The layout remains usable on mobile while prioritizing desktop scanability.

Scan-context forms and listings replace airport language with `Travel pickup`. Scanner, history, and scan list views display the travel pickup attribute without plane-specific icons or copy.

## Security and Data Integrity

Travel lookup and dismissal actions must scope records through the current event. Existing admin and API authorization remains in force. The journey builder receives only records already authorized and selected by the controller.

Column migrations preserve values and are reversible. API compatibility aliases expose no information that the canonical fields do not already expose.

Creating the first scan in an explicit travel pickup context marks the final inbound plane leg's travel pickup timestamp when a leg exists. Non-plane travel relies on the scan itself, so no synthetic leg is created. Creating a venue check-in scan does not write that timestamp. Duplicate scans do not rewrite the original pickup timestamp.

## Failure and Edge Cases

- Missing times place entries in `Unscheduled`.
- Missing route fields render the remaining known details or a neutral `Details not provided` label.
- A registration with travel but no plane legs still appears when its mode is not plane.
- A plane journey without valid legs appears as unscheduled rather than crashing or disappearing.
- If both travel pickup and venue check-in scans exist, the entry reports `collected`.
- Manual dismissal is subordinate to scan-derived states.
- Legacy Airport Mode links remain functional.
- A travel-disabled event retains the existing redirect and alert behavior.

## Testing

Development follows red-green-refactor cycles.

Unit tests for the journey builder cover all five modes, timestamp selection, event-timezone grouping inputs, deterministic sorting, partial data, unscheduled entries, and pickup-state precedence.

Request tests cover the canonical admin and API routes, combined inbound/outbound output, filters, current-event scoping, travel-disabled behavior, legacy route compatibility, and canonical plus deprecated API fields.

Scan request and toolbox tests prove that explicit travel pickup scans record collection, venue check-in resolves the calendar without recording collection, duplicate scans preserve the first pickup, and non-plane pickup works through scan state.

Model tests cover the renamed scan-context attribute and travel-leg pickup methods. Migration behavior is verified through the resulting schema and focused tests where practical.

After automated tests and lint pass, browser verification covers desktop and mobile layouts in light and dark themes, including a populated agenda, unresolved pickups, filters with no results, and unscheduled travel.

## Completion Criteria

Issue 37 is complete when staff can use the Travel Calendar to see chronological inbound and outbound travel for every mode, travel pickup contexts track collection beyond airports, venue check-in resolves pickup without masquerading as collection, canonical and compatibility interfaces work, and the relevant automated and browser checks pass.
