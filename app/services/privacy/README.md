# Privacy requests (GDPR deletion and export)

Deletion and export requests are run from the Hack Club privacy hub at
https://yeet.hackclub.com (spec: https://yeet.hackclub.com/docs/deletions). The
hub calls these endpoints once with `dry_run: true`. A human reviews the
result, and after approval the hub calls again for real.

| Endpoint | Does |
| --- | --- |
| `POST /api/privacy/delete` | Erases the subject, or reports what would be erased on a dry run |
| `POST /api/privacy/export` | Reports what is held. Export delivery isn't specified yet, so it never changes anything |

`Api::PrivacyController` inherits `ActionController::API`, so none of
`ApplicationController`'s session, Pundit or audit-log callbacks run.

## Authentication

Each call carries `Authorization: Bearer <token>`: an ES256 JWT signed by the
hub. `Privacy::Token` verifies it with Ruby's OpenSSL against the hub's JWKS
(`https://yeet.hackclub.com/.well-known/jwks.json`). It checks:

- the signature, `kid`, and `typ: JWT`
- `iss` is `hackclub-privacy` and `aud` is `attend`
- `exp` and `iat`, with a lifetime of at most 300 seconds and 30 seconds of leeway
- the shape of the claims, and that `action` matches the endpoint called

Keys are cached for 5 minutes and refetched when an unknown `kid` shows up, so
key rotation on the hub needs no change here. `PRIVACY_JWKS_URL` only exists
to point at a hub running locally.

The endpoints act only on the token claims, never the request body. Each
token's `jti` is accepted once: used IDs go in `privacy_token_uses` in
Postgres (not `Rails.cache`), pruned after a day.

Responses:

- `200 {request_id, found, dry_run, deleted: {table: rows}, retained: [{type, count, reason}]}`.
  Once someone is erased, later calls answer `found: false`.
- `401 {error}` for a bad token, `400 action_mismatch`, `409 replayed`
- `409 {error: "manual_review_required", reason}`, see below
- `503` when the JWKS can't be fetched. The hub retries.

Only the `request_id`, dry-run flag and outcome are logged.

## Who is matched

Emails are compared case-insensitively.

- **Users** by `email`, `hack_club_account_id` (the subject's `identity_id`) or `slack_user_id`
- **Participants** by `email`, linked user, or a `slack_user_id` on the participant or any of their registrations
- **Guardians** by `email` or linked user
- Loose rows by any of the matched people's emails or phone numbers: emergency
  contacts on other people's registrations, invitations, email logs, message
  deliveries, automated SMS logs and support tickets

## Needs a human first

These answer `409 manual_review_required` without changing anything. Staff
deal with the cause in Attend, then rerun the request from the hub.

| `reason` | When | Why |
| --- | --- | --- |
| `staff_account` | Global role, event or series role, or an API token | Staff authored incidents, notes, messages and audit history other records depend on, and their tokens may feed other services |
| `event_not_over` | A registration, guardian link or emergency-contact entry for an event that hasn't ended | Pulling someone out of an upcoming or running event changes organisers' headcount, rooming and medical lists, so organisers remove the registration first |
| `safeguarding_record` | Named in an incident, or filed or commented on an incident report | Safeguarding records have their own retention rules, and the safeguarding lead decides |
| `banned` | One of their emails is on a ban list | Erasing would lift the ban |
| `unexpected_reference` | A foreign key the eraser doesn't plan for | Something references them that needs a look; the whole run rolls back |

Exports skip every check except `staff_account`.

## What is erased

All in one transaction, with PaperTrail switched off:

- the user account, with its mobile and push tokens, passports, NFC tokens and badge redirect
- the participant, with sibling-group memberships, headshot and public-profile photo
- every registration and everything hanging off it: medical, dietary,
  accessibility, safeguarding info, accommodation, travel and travel legs,
  emergency contacts, consents (and paper uploads), rooming, roommate
  preferences either way, groups, scans, change requests, Slack blast and
  message deliveries, wallet passes, staff notes, and the proof uploaded for
  under-minimum-age checks
- guardians matched directly, and guardians whose only links were to the
  registrations being erased; a guardian with another child still on file keeps
  their row and loses only the erased links
- support tickets with their messages and notes, invitations, email logs and
  automated SMS logs
- PaperTrail versions and audit-log entries for every one of those rows.
  Versions they authored keep their content with `whodunnit` cleared

Attachment rows go in the transaction; their blobs are purged after a real run
commits.

## Kept, and reported as `retained`

| Kept | Why |
| --- | --- |
| Signed documents in DocuSeal | Liability records. Attend's own consent rows go, so it no longer links to them |
| Airtable copies | Synced to event organisers' Airtable bases, which aren't touched here |

## Dry runs

A dry run performs the real erasure inside a transaction, reads the per-table
delete counts Postgres tracks for it (`pg_stat_xact_user_tables`), and rolls
back. Dry run and real run share one code path, so the reviewed numbers are
the executed numbers.

## Not covered

- Slack: channel membership and messages already sent
- DocuSeal submissions, Postmark and Twilio message history, and AppSignal data
- Broadcast messages they received keep their body and recipient count; only the per-person delivery row goes

## Running it against a local hub

```sh
# .env
PRIVACY_JWKS_URL=http://localhost:44100/.well-known/jwks.json
```

In the hub, register a target with slug and audience `attend` and base URL
`http://localhost:3000`.
