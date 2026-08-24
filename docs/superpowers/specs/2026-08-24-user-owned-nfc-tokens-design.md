# Hack Club Passports Design

## Summary

Attend supports two deliberately different kinds of NFC hardware:

1. An event badge belongs to one `ParticipantEvent` and is valid only at that event.
2. A Hack Club passport belongs to one `User` and may identify that user at every event where they have a participation.

This change adds passports without changing the ownership or issuance semantics of event badges. Global administrators pair passports from the target user's admin profile. A user with a successfully paired passport sees a basic Hack Club Passport section on `/dashboard/profile` containing its public serial number, status, and pairing date.

Every event scanner accepts active passports. The existing `Event#nfc_badges_enabled?` setting continues to control only whether that event issues and writes its own event-scoped NFC badges.

## Goals

- Keep every existing and newly issued event NFC badge scoped to its `ParticipantEvent`.
- Add durable Hack Club passports owned by `User`.
- Pair and revoke passports from the global admin user profile.
- Resolve an active passport to its owner's participation in the scanner's selected event.
- Let every event accept passports regardless of `event.nfc_badges_enabled?`.
- Show paired passport information to its owner on the dashboard profile.
- Give each passport a public serial number separate from its private NFC bearer token.
- Preserve current event badge web, mobile API, and bridge behavior.

## Non-Goals

- No participant self-service pairing or revocation.
- No event scanner control for creating or pairing passports.
- No native mobile pairing UI.
- No public or unauthenticated passport lookup.
- No visual passport artwork, achievements, stamps, or rich passport history.
- No migration of event badges into passports.
- No feature flag framework or Flipper installation.

## Product Semantics

### Event NFC badges

Event badges remain stored on `ParticipantEvent` using the existing `nfc_badge_token`, `nfc_badge_assigned_at`, and `nfc_badge_assigned_by_id` columns. The existing scanner write flow and nested event badge endpoints continue to create, write, confirm, and reset these values.

An assigned event badge is accepted only when scanning its owning event. It must never resolve the same participant at another event.

`event.nfc_badges_enabled?` retains its current meaning: this event issues NFC badges. It gates event badge token generation, write controls, confirmation, and reset.

### Hack Club passports

A passport belongs to a `User`, independently of any event or participation. Global administrators pair it from `/admin/users/:id`. An active passport is accepted at every event, but check-in still requires the owner to have a `ParticipantEvent` for the scanner's selected event.

Passport pairing does not depend on an event or event flag. Passport visibility is data-driven, with no feature flag. The participant-facing profile shows the passport section only after at least one passport has been successfully paired. A cancelled pending write does not create a participant-facing indication.

## Data Model

Add `Passport` with a UUID primary key and these fields:

- `token: uuid`, non-null, globally unique, private bearer identifier written to NFC
- `serial_number: string`, non-null, globally unique, public identifier such as `HCP-A1B2C3D4`
- `user_id: uuid`, non-null foreign key to `users`
- `paired_at: datetime`, nullable while the hardware write is pending
- `paired_by_id: uuid`, nullable foreign key to `users`
- `revoked_at: datetime`, nullable
- `revoked_by_id: uuid`, nullable foreign key to `users`
- timestamps

Associations:

```ruby
class User < ApplicationRecord
  has_many :passports, dependent: :destroy
end

class Passport < ApplicationRecord
  belongs_to :user
  belongs_to :paired_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true
end
```

A user may have multiple passports so lost hardware can be replaced without rewriting history. A passport is:

- pending when `paired_at` and `revoked_at` are both null
- active when `paired_at` is present and `revoked_at` is null
- revoked when `revoked_at` is present

The serial number is generated when the pending record is created and protected by a unique database index. It is safe to display. The raw `token` is never displayed on user-facing pages, included in URLs, audit metadata, or logged.

## Passport Pairing Lifecycle

The admin user show page lists the user's passports and provides a `Pair passport` control. The page is already restricted to global administrators.

Pairing uses the Attend NFC Bridge:

1. The administrator connects the bridge from the user profile.
2. `POST /admin/users/:user_id/passports` returns the user's latest pending passport or creates one.
3. The browser sends the passport's private token to the bridge as the Attend NFC token.
4. The administrator taps the hardware so the bridge writes it.
5. The bridge requests a second tap and reads the written token back.
6. `POST /admin/users/:user_id/passports/:id/confirm` confirms only an exact match with that pending passport.
7. Confirmation records `paired_at` and `paired_by`.

A failed or cancelled write leaves a pending record that a later pairing attempt may reuse. Pairing another passport does not revoke existing active passports.

`DELETE /admin/users/:user_id/passports/:id` revokes one passport, recording `revoked_at` and `revoked_by`. Revoked passports remain visible in admin history and on the owner's passport section with a revoked status, but they can no longer check anyone in.

Audit logs reference the `Passport` record and target user. They do not include the private token.

## NFC Scan Resolution

Browser and API scan controllers share an NFC resolver:

```ruby
NfcTokenResolver.call(event:, token:)
# => ParticipantEvent or nil
```

Resolution order is intentional:

1. Find an assigned `ParticipantEvent` badge matching the token within the selected event.
2. If no current-event badge matches, find an active `Passport` by exact token.
3. Follow `passport.user.participant`.
4. Find that participant's `ParticipantEvent` for the selected event.
5. Return nil if the token is unknown, the passport is pending or revoked, the user has no linked participant, or the participant is not enrolled in the selected event.

The selected event always owns the resulting `Scan`. Scan context, source, deduplication, and check-in behavior remain unchanged.

An event badge is never looked up globally. Existing event badges therefore remain event-scoped. Passport reads do not depend on `event.nfc_badges_enabled?`.

## Event Scanner UI

The NFC reader connection and read status render at every event so any event can accept a passport.

The existing event badge write panel, automatic write-on-check-in behavior, and participant modal controls retain their current behavior and remain conditional on `current_event.nfc_badges_enabled?`. They operate only on `ParticipantEvent` badge fields.

The event scanner has no `Pair passport` action and does not create `Passport` records.

## Admin User Profile UI

`/admin/users/:id` gains a dashed orange global-admin section for Hack Club Passports. It contains:

- bridge connection status and connect/disconnect control
- `Pair passport` button
- pending write and verification status
- a list of passport serial numbers, status, pairing date, pairing administrator, and revocation date
- a revoke action for active passports

The private NFC token is present only in the authenticated pairing response and transient browser-to-bridge write message. It is not rendered into the initial HTML.

## Participant Profile UI

`/dashboard/profile` gains a `Hack Club Passport` navigation item and section only when `current_user.passports.where.not(paired_at: nil).exists?`.

The baseline section lists successfully paired passports with:

- serial number
- active or revoked status
- pairing date

It does not show the private token, pairing administrator, administrative controls, or pending writes. The section is informational only.

## Existing Event Badge Compatibility

The original event badge lifecycle is restored in full:

- `ParticipantEvent#ensure_nfc_badge_token!`
- `ParticipantEvent#assign_nfc_badge!`
- `ParticipantEvent#reset_nfc_badge!`
- browser and API event badge controllers
- mobile participant and scan response fields
- scanner write-on-check-in provisioning
- toolbox check-in provisioning

There is no event-badge-to-passport backfill. Existing assigned badges remain valid only at their original events.

The unmerged PR's Flipper installation, `NfcToken` model, global event badge backfill, and user-owned behavior in the event badge endpoints are removed before the PR is allowed to merge.

## Authorization and Security

- Passport pairing and revocation require the existing global-admin authorization on admin user management.
- Passport scanning requires the existing authenticated event access used by scan creation.
- Confirmation requires an exact token match against the selected pending passport.
- Unknown, malformed, pending, and revoked passport tokens do not create scans.
- A valid passport reveals nothing when its owner is not enrolled in the selected event.
- Raw passport tokens are filtered from Rails parameter logs and omitted from audit metadata.
- Unique database indexes protect both bearer tokens and public serial numbers.
- Participant-facing pages never receive the private token.

## Errors and Feedback

- Bridge unavailable: show a connection error on the admin user page.
- Write failed: leave the passport pending and allow retry.
- Verification mismatch: do not pair; ask the administrator to retry.
- Revoked or unknown scan token: return the existing participant-not-found response.
- Passport owner not enrolled in the event: return the same participant-not-found response.

Error messages do not reveal passport ownership to event staff outside their selected event.

## API and Documentation

The existing event badge API remains documented as participation-owned and event-scoped.

Passport pairing routes are authenticated web-session admin routes rather than mobile API routes. The mobile scan endpoint needs no new input: `badge_token` can contain either a current-event badge token or a passport token, and the server performs scoped resolution.

OpenAPI scan documentation states that event badges work only at their event while active passports work across events.

## Testing Strategy

Model specs cover:

- unique private tokens and serial numbers
- pending, active, and revoked states
- exact-match confirmation and staff attribution
- revocation of one passport without affecting another
- multiple passports per user

Resolver specs cover:

- current-event badge resolution
- rejection of an event badge at another event
- active passport resolution across events
- no participation in the selected event
- unknown, malformed, pending, and revoked passports
- current-event badge precedence

Request and view specs cover:

- global-admin-only passport creation, confirmation, and revocation
- admin user profile pairing controls and passport history
- participant profile visibility only after successful pairing
- participant profile serial/status/date output without the bearer token
- NFC reading at events with badge issuance disabled
- unchanged event badge issuance and mobile response behavior
- unchanged QR and manual scanning behavior

The focused suite runs first, followed by RuboCop, OpenAPI parsing, and the complete RSpec suite with existing baseline failures reported separately.

## Rollout

1. Deploy the `passports` table, admin pairing flow, profile section, and dual resolver.
2. Pair internal passports from the admin user profile and verify scanning at multiple events.
3. Monitor unknown-token and revoked-token scan behavior without logging token values.
4. Add native mobile passport administration or richer passport presentation in later changes.
