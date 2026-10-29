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
- `503 {error}` for anything worth retrying: `jwks_unavailable` when the JWKS
  can't be fetched, `storage_unavailable` when attachment files couldn't be
  deleted, `database_busy` when the matched rows stayed locked by other work.
  The hub retries with a fresh token.

Only the `request_id`, dry-run flag and outcome are logged.

## Who is matched

Emails are compared case-insensitively.

Accounts are matched only on what Hack Club Auth vouches for. Profiles carry
emails and Slack IDs that anyone can type, so those can find a profile but
never reach into an account on their own:

- **Users** by `email` (synced from HCA at sign-in), `hack_club_account_id`
  (the subject's `identity_id`), or the verified Slack ID in their HCA claims.
  An email-only placeholder without an HCA identity needs review. The editable
  Slack override does not establish or hide an account match
- **Participants** by linked user or their own `email`; editable Slack IDs
  require one of those independent matches
- **Guardians** by linked user; a standalone editable email match needs review
- Every profile on a matched account goes with it

Anything that points at an account the subject's verified identifiers don't
reach stops the run with `identity_conflict`: a participant or guardian
matched on its own email or Slack ID but linked to an unmatched account, an
account whose HCA identity differs from the subject's `identity_id`, or a
participant found only through a Slack ID on a profile or registration (typed by
whoever registered them, often an organiser). A profile no account has
claimed, like an imported one, is erased on its own email.
- Emergency contacts on other people's registrations, by the subject's own emails
- Invitations, email logs and message deliveries, by emails from the hub or
  matched HCA accounts, or their direct links to erased people and registrations.
  Editable profile and guardian emails never expand these searches
- Automated SMS logs and support tickets, by the matched people's phone numbers.
  A number that anyone staying on file also has is never used, since children
  often give a parent's number. Tickets filed against another person always stay
- Visa letter applications by matched account, the registration they led to,
  or their email (copied from the applicant's account when they applied; Envoy
  imports have no account until claimed). One with the email but linked to an
  unmatched account is an `identity_conflict`. Visa letter invitations by
  emails from the hub or matched HCA accounts
- Import batches whose uploaded CSV rows or per-row errors hold emails from
  the hub or matched HCA accounts. CSV rows also match on the subject's Slack ID;
  a typed email on a Slack-matched row never expands the search to other rows

An empty email list never matches blank-email rows; Slack matching still applies.

## Needs a human first

These answer `409 manual_review_required` without changing anything. Staff
deal with the cause in Attend, then rerun the request from the hub.

| `reason` | When | Why |
| --- | --- | --- |
| `staff_account` | Global role, event or series role, or an API token | Staff authored incidents, notes, messages and audit history other records depend on, and their tokens may feed other services |
| `event_not_over` | A registration, guardian link or emergency-contact entry for an event that hasn't ended, including one without an end time | Pulling someone out of an upcoming or running event changes organisers' headcount, rooming and medical lists, so organisers remove the registration first |
| `visa_letter_active` | A visa letter application still pending or approved, or a sent letter for an event that hasn't ended | Embassies check letters against `/verify` until the trip is over, so staff reject the application or the event ends first |
| `safeguarding_record` | Named in an incident, filed or commented on an incident report, or has a pending or upheld training disclosure | Safeguarding records have their own retention rules, and the safeguarding lead decides |
| `banned` | One of their emails is on a ban list | Erasing would lift the ban |
| `identity_conflict` | An editable email or Slack ID leads to an account the subject's verified identifiers don't (see above) | It may be someone else's account; a human works out whose it is |
| `import_in_progress` | An import holding their row is pending or running | The import would write its copy of them back |
| `unexpected_reference` | A foreign key the eraser doesn't plan for | Something references them that needs a look; the whole run rolls back |

Exports skip every check except `staff_account` and `identity_conflict`.

### Concurrent changes

Matching, the checks and the erasure run in one transaction. The matched
users, participants, registrations, guardians, guardian links and import
batches, plus dependent training and volunteer records, are locked `FOR UPDATE`
and their events `FOR SHARE`, then matched
again; if the match moved while waiting, it goes round again. With those locks
held, a role assignment, incident, registration or guardian link created
mid-run waits for the erasure and then fails its foreign key, a role change or
event date change waits, and an import can't be confirmed. Lock waits give up
after 5 seconds with `503 database_busy`.

Email logs, invitations, emergency contacts, message deliveries, SMS logs,
tickets, visa letter applications and visa letter invitations also match
without an account foreign key. Before matching, their
tables are locked `SHARE ROW EXCLUSIVE` for the transaction: reads continue,
but writes wait, including inserts that row locks would miss. This briefly
pauses unrelated writes to those tables too; it does not prevent new data
being recorded after the transaction ends.

Ban emails and incident reports filed by email have no foreign key to the
person, so one added in the instant between the check and the commit isn't
held off.

## What is erased

All in one transaction, with PaperTrail switched off:

- the user account, with its mobile and push tokens, passports, badge
  redirect, and MCP OAuth grants, tokens and connection settings
- training enrollments, progress, badge awards, course invitations, nonblocking
  safety disclosures and volunteer records, including their versions and audit logs
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
- visa letter applications with their letter PDF, and visa letter invitations
- their rows in import batches. Their own rows are removed; where they're only
  the parent or emergency contact on someone else's row, those columns come off
  it. Per-row errors naming them go. Reported as `import_batches.rows_data` and
  `import_batches.errors_data`, counting rows changed
- PaperTrail versions and audit-log entries for every one of those rows.
  Versions they authored keep their content with `whodunnit` cleared

Attachment, variant and blob rows go in the transaction. On a real run the
files are deleted from storage before it commits; if that fails, the whole run
rolls back and answers `503 storage_unavailable`, so the hub's retry still
finds the person and finishes. A commit that fails after the files went leaves
the rows for the retry, which deletes the (already missing) files again
harmlessly. A blob that something else still has attached is left alone.

## Kept, and reported as `retained`

| Kept | Why |
| --- | --- |
| Signed documents in DocuSeal | Liability records. Attend's own consent rows go, so it no longer links to them |
| Unsigned documents in DocuSeal | Sent for signature but never signed. The submission isn't cancelled or deleted from here; Attend's link to it goes |
| Documents a guardian signed for a child who stays registered | The consent and any paper upload belong to the child's registration; the link to the erased guardian and their DocuSeal signing reference are removed from it and from its PaperTrail history |
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
