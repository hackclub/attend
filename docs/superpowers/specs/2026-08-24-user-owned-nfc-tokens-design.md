# User-Owned NFC Tokens Design

## Summary

Attend currently provisions NFC badge tokens on `ParticipantEvent`. That makes a physical badge valid for one participation at one event. This change introduces durable NFC tokens owned by `User`, so the same physical token can identify its owner at every event where that user has a participation.

Every event accepts existing user-owned NFC tokens. The existing `Event#nfc_badges_enabled?` setting remains, but its meaning narrows to whether the event issues and writes NFC hardware. An event with issuance disabled can still read an existing personal token and check its owner in.

The design borrows the durable-artifact lifecycle from the Ruby Passport: a physical artifact is paired once, then carried between events. Attend continues to record check-in against the participation in the scanner's selected event.

## Goals

- Pair NFC hardware with a user rather than a participation.
- Let every event accept a paired personal token.
- Resolve a scanned token to the user's participation in the scanner's current event.
- Preserve every existing assigned NFC token without silently invalidating hardware.
- Keep event-issued badge provisioning behind `Event#nfc_badges_enabled?`.
- Install Flipper with PostgreSQL persistence and support the per-user `:personal_nfc_token` actor flag.
- Retain the existing web and mobile API shapes where practical.

## Non-Goals

- No participant-facing NFC or passport UI is added in this change.
- No Flipper administration UI is mounted. Flags are managed through Rails console initially.
- No native mobile pairing UI is added.
- No public or unauthenticated token lookup endpoint is added.
- Legacy `ParticipantEvent` NFC columns are not dropped in this rollout.
- A second event-level setting for accepting personal tokens is not added. Acceptance is universal.

## Product Semantics

There are two distinct capabilities:

1. **Personal token acceptance**: every event scanner may read an existing user-owned NFC token. This is not controlled by an event flag.
2. **NFC hardware issuance**: only events with `nfc_badges_enabled?` may generate, write, confirm, replace, or revoke event-issued hardware.

The scanner's NFC reader connection and read status are visible to staff at every event. Badge-writing and pairing controls are rendered only when `current_event.nfc_badges_enabled?` is true.

The per-user Flipper flag is `:personal_nfc_token`. It is intended to gate participant-facing references to the feature. Since this change adds no participant-facing UI, the flag does not gate staff pairing or check-in. All Flipper features remain disabled by default, and a user can later be enabled with:

```ruby
Flipper.enable_actor(:personal_nfc_token, user)
```

## Data Model

Add `NfcToken` with a UUID primary key and the following fields:

- `token: uuid`, non-null, database-generated, globally unique
- `user_id: uuid`, non-null foreign key to `users`
- `paired_at: datetime`, nullable while a write is pending
- `paired_by_id: uuid`, nullable foreign key to `users`
- `revoked_at: datetime`, nullable
- `revoked_by_id: uuid`, nullable foreign key to `users`
- timestamps

Associations:

```ruby
class User < ApplicationRecord
  has_many :nfc_tokens, dependent: :destroy
end

class NfcToken < ApplicationRecord
  belongs_to :user
  belongs_to :paired_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true
end
```

A user may own multiple tokens. This is required to preserve badges previously issued for different events and permits hardware replacement without conflating the hardware records. A token is usable only when `paired_at` is present and `revoked_at` is absent.

The token value is a bearer identifier written to the NFC tag's Attend record. It remains directly queryable because scanner lookup is its purpose. Raw token values must not be added to audit metadata, logs, participant-facing HTML, or URLs. Audit records reference the `NfcToken` record and user instead.

## Flipper Installation

Add the official `flipper` and `flipper-active_record` gems. Recreate `flipper_features` and `flipper_gates` with the current generator schema, including a text gate value and the unique indexes required by the Active Record adapter. Configure Flipper to use `Flipper::Adapters::ActiveRecord` rather than its in-memory default.

`User#flipper_id` returns a stable type-qualified identifier:

```ruby
def flipper_id
  "User;#{id}"
end
```

The explicit method prevents an actor identifier from depending on display attributes or object serialization.

## Pairing Lifecycle

Pairing reuses the existing authenticated staff scanner and local NFC bridge:

1. Staff select or check in a participant in an event with NFC issuance enabled.
2. Attend verifies that the participant is linked to a `User`. An unlinked participant cannot receive a personal token.
3. The ensure endpoint returns that user's latest unconfirmed, unrevoked token or creates a pending `NfcToken`.
4. The staff bridge writes the UUID token value into the hardware's Attend NFC record.
5. The bridge reads the value back and sends it to the confirm endpoint.
6. Confirmation succeeds only when the supplied value matches the pending record. It sets `paired_at` and `paired_by`.
7. Cancelling or failing a write leaves an unusable pending record. A later ensure request may reuse it.

Pairing endpoints remain nested under event and participation routes for authorization and mobile compatibility, but they operate on `participant_event.participant.user.nfc_tokens`. They require both staff access to the event and `event.nfc_badges_enabled?`.

Re-pairing creates or confirms another hardware record; it does not invalidate other tokens belonging to the same user. Explicit revocation targets one `NfcToken` and records the staff actor. The existing reset compatibility endpoint returns a fresh pending user token and must not silently revoke all of a user's hardware.

## Scan Resolution

Both browser and API scan controllers use one resolver with this interface:

```ruby
NfcTokenResolver.call(event:, token:)
# => ParticipantEvent or nil
```

The resolver performs these steps:

1. Find an active `NfcToken` by exact UUID value.
2. Follow `nfc_token.user.participant`.
3. Find that participant's `ParticipantEvent` for the supplied event.
4. Return `nil` if the token is unknown, pending, revoked, the user has no linked participant, or the participant is not enrolled in the event.

The controllers continue to create `Scan` rows against the returned `ParticipantEvent`, using the selected `ScanContext` and `source: "nfc"`. Existing scan deduplication and first-scan check-in behavior remain unchanged.

NFC token reads do not depend on `event.nfc_badges_enabled?`. QR and manual lookup behavior remain unchanged.

## Legacy Migration and Compatibility

Existing assigned `ParticipantEvent` tokens are physical hardware and must remain valid.

The data migration copies every row with all of the following into `nfc_tokens`:

- `nfc_badge_token` is present
- `nfc_badge_assigned_at` is present
- `participant.user_id` is present

It preserves the token UUID, pairing timestamp, and assigning staff member. The globally unique token index makes the backfill idempotent and prevents one token from being assigned to two users.

Assigned tokens on participants without linked users cannot yet have a user owner. Their legacy columns remain untouched. The resolver therefore has a read-only compatibility fallback:

1. Find a legacy `ParticipantEvent` globally by `nfc_badge_token` and require `nfc_badge_assigned_at`.
2. If its participant is now linked to a user, resolve that user's participation in the scanner's current event.
3. If it is still unlinked, accept the token only for that original `ParticipantEvent` and only when scanning its original event.

No new flow generates, writes, confirms, or resets `ParticipantEvent#nfc_badge_token`. Existing columns and model methods are marked deprecated and retained only for compatibility. They can be removed in a later migration after production data confirms that no assigned unlinked legacy tokens remain.

The existing nested NFC badge API routes remain available. Their response keys stay compatible, while the backing record changes to `NfcToken`. Participant list/detail responses expose only the token needed by authenticated staff issuance flows and must not create records during reads.

## Authorization and Security

- Scan creation keeps its current event-access requirements.
- Personal tokens are accepted only through authenticated staff scanner/API requests.
- Issuance endpoints additionally require `event.nfc_badges_enabled?`.
- Pairing requires a target participation in the staff member's accessible event.
- Pairing fails for an unlinked participant rather than creating or guessing an account.
- Confirmation requires an exact match with a pending token owned by the target user.
- Unknown, pending, revoked, and mismatched tokens do not create scans.
- Raw UUID values are excluded from audit metadata and application logs.
- Database uniqueness is the final guard against duplicate token ownership.

## Errors and Staff Feedback

- Unknown, pending, revoked, or out-of-event token: `Participant not found for this event`.
- Pairing at a non-issuing event: `NFC badge issuance is not enabled for this event`.
- Pairing an unlinked participant: `Participant must have a linked Attend account before pairing a personal NFC token`.
- Confirmation mismatch: `Badge token mismatch`.
- Missing pending token: `No pending NFC token exists for this user`.
- Reader or bridge failures remain client-side connection/write errors and do not activate the pending record.

Messages do not reveal whether a token belongs to a user registered elsewhere.

## UI Changes

The staff scanner changes in two ways:

- The NFC connection/read section renders for every event.
- NFC write, pair, and rewrite controls render only for events with `nfc_badges_enabled?`.

The participant result modal reports whether the linked user has active or pending tokens, not whether the current `ParticipantEvent` has a token. The pairing button is unavailable with a clear explanation when the participant has no linked user.

No dashboard, profile, onboarding, ticket, email, wallet pass, or participant-facing copy mentions personal NFC tokens in this change. Future user-visible work must use:

```ruby
Flipper.enabled?(:personal_nfc_token, current_user)
```

## API and Documentation

The OpenAPI document keeps `badge_token` as the scan input and retains the current issuance route paths. NFC badge schemas are updated so their ownership and lifecycle descriptions refer to the user's token rather than the participation's token.

The mobile app does not need a route migration for existing scan calls. A future native pairing interface can use the retained ensure/confirm routes until a dedicated user-token API is justified.

## Testing Strategy

Model specs cover:

- globally unique token values
- pending, active, and revoked states
- multiple active tokens for one user
- confirmation and revocation actor/timestamp behavior
- stable `User#flipper_id`

Resolver specs cover:

- resolving one token to the same user across two events
- rejecting a user without participation in the selected event
- rejecting unknown, pending, and revoked tokens
- resolving migrated legacy tokens across events
- limiting unlinked legacy tokens to their original event

Request specs cover both admin browser and API scan creation:

- NFC acceptance when `nfc_badges_enabled?` is false
- unchanged QR/manual behavior
- correct scan source and current-event participation
- issuance rejected when the event flag is false
- issuance rejected for an unlinked participant
- ensure and confirm operating on `NfcToken`
- confirmation mismatch and missing pending token
- retained response keys for mobile compatibility

View/request specs cover universal reader visibility and issuance-only controls. Migration verification covers preservation of token UUIDs, pairing timestamps, and assigning staff for linked legacy rows, with unlinked rows left intact for fallback.

The focused specs run first, followed by the complete RSpec suite and RuboCop.

## Rollout

1. Deploy Flipper tables, `nfc_tokens`, and the legacy backfill.
2. Deploy universal token resolution and the updated staff scanner.
3. Verify legacy fallback use and the count of assigned legacy tokens without linked users.
4. Enable `:personal_nfc_token` for internal test users in environments where future user-facing work is being developed. This flag has no visible effect in the current change.
5. Add native mobile pairing in a later change.
6. Remove legacy participation token columns only after no assigned unlinked tokens remain and all supported clients use user-owned tokens.

