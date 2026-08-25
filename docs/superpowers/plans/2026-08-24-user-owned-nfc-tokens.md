# Hack Club Passports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-owned Hack Club passports that work at every event without changing existing event-scoped NFC badges.

**Architecture:** Keep the existing `ParticipantEvent` badge lifecycle and APIs intact. Store passports in a separate `Passport` model owned by `User`, administer them only from global admin user profiles, and resolve scans by checking the selected event's badge before an active passport. Render passport details on the owner's dashboard profile from persisted data, with no feature flag.

**Tech Stack:** Rails 8.1, PostgreSQL UUIDs, RSpec, ERB, Stimulus, Attend NFC Bridge WebSocket protocol, OpenAPI YAML.

**Spec:** `docs/superpowers/specs/2026-08-24-user-owned-nfc-tokens-design.md`

## Global Constraints

- Existing NFC badges remain owned by `ParticipantEvent` and valid only at their event.
- Every event accepts active passports regardless of `event.nfc_badges_enabled?`.
- `event.nfc_badges_enabled?` continues to gate only event badge issuance and writing.
- Passport pairing and revocation happen only on the global admin user profile.
- No Flipper gems, initializer, tables, actor method, or feature gates remain.
- No event-badge-to-passport backfill is created.
- The private passport token is filtered from logs and never shown in HTML or audit metadata.
- A public serial number uses the exact format `HCP-XXXXXXXX`.

---

### Task 1: Restore Event Badges and Remove Flipper

**Files:**
- Modify: `Gemfile`, `Gemfile.lock`, `app/models/user.rb`, `app/models/participant_event.rb`
- Modify: `app/controllers/admin/participant_events_controller.rb`, `app/controllers/api/v1/nfc_badges_controller.rb`
- Modify: `app/controllers/admin/scans_controller.rb`, `app/controllers/api/v1/scans_controller.rb`, `app/controllers/api/v1/participants_controller.rb`
- Modify: `app/toolboxes/participant_events_toolbox.rb`, `config/openapi.yml`, `db/schema.rb`
- Delete: `config/initializers/flipper.rb`, `db/migrate/20260824130001_create_flipper_tables.rb`, `db/migrate/20260824130003_backfill_user_owned_nfc_tokens.rb`
- Test: `spec/models/participant_event_spec.rb`, `spec/requests/api/v1/nfc_badges_spec.rb`, `spec/requests/api/v1/participants_spec.rb`, `spec/toolboxes/participant_events_toolbox_spec.rb`, `spec/models/user_spec.rb`

**Interfaces:**
- Produces: `ParticipantEvent#ensure_nfc_badge_token! -> String`, `#assign_nfc_badge!(user:)`, `#reset_nfc_badge!`, and the original event badge request/response contract.

- [ ] **Step 1: Restore failing event badge regression specs**

Add or restore examples proving that `ensure_nfc_badge_token!` persists a UUID on the participation, `assign_nfc_badge!` records staff and time, `reset_nfc_badge!` replaces the UUID, API ensure/confirm/reset mutate only that participation, and toolbox check-in provisions only the participation badge when enabled.

```ruby
expect { participant_event.ensure_nfc_badge_token! }
  .to change(participant_event, :nfc_badge_token).from(nil)
expect(user.reload).not_to respond_to(:nfc_tokens)
```

- [ ] **Step 2: Run the restored specs and verify red**

Run: `mise x ruby@3.4.7 -- bundle exec rspec spec/models/participant_event_spec.rb spec/requests/api/v1/nfc_badges_spec.rb spec/requests/api/v1/participants_spec.rb spec/toolboxes/participant_events_toolbox_spec.rb spec/models/user_spec.rb`

Expected: failures reference `NfcToken`, missing participant-event lifecycle methods, and Flipper expectations.

- [ ] **Step 3: Restore the original event badge implementation**

```ruby
def nfc_badge_assigned?
  nfc_badge_token.present? && nfc_badge_assigned_at.present?
end

def ensure_nfc_badge_token!
  return nfc_badge_token if nfc_badge_token.present?
  update!(nfc_badge_token: SecureRandom.uuid)
  nfc_badge_token
end

def assign_nfc_badge!(user:)
  update!(nfc_badge_assigned_at: Time.current, nfc_badge_assigned_by: user)
end

def reset_nfc_badge!
  update!(nfc_badge_token: SecureRandom.uuid, nfc_badge_assigned_at: nil, nfc_badge_assigned_by: nil)
end
```

Restore controllers, scanner/toolbox provisioning, participant payload fields, and OpenAPI NFC-badge descriptions to their `origin/main` behavior.

- [ ] **Step 4: Remove Flipper and the incorrect global-token artifacts**

Remove both gems and lockfile entries, `User#flipper_id`, Flipper specs/initializer/migration, the `NfcToken` association/model/factory/spec, and the global backfill migration/spec. Remove `nfc_tokens` and Flipper tables/foreign keys from `db/schema.rb`.

- [ ] **Step 5: Verify green and commit**

Run the Step 2 command and `rg -n "Flipper|flipper|NfcToken|nfc_tokens|personal_nfc_token" Gemfile Gemfile.lock app config db spec`.

Expected: specs pass; the search finds only the historical `20260813120000_drop_flipper_tables.rb` migration.

Commit: `fix: preserve event scoped nfc badges`

---

### Task 2: Passport Model and Lifecycle

**Files:**
- Create: `app/models/passport.rb`, `spec/factories/passports.rb`, `spec/models/passport_spec.rb`
- Replace: `db/migrate/20260824130002_create_nfc_tokens.rb` with `db/migrate/20260824130002_create_passports.rb`
- Modify: `app/models/user.rb`, `app/models/audit_log.rb`, `config/initializers/filter_parameter_logging.rb`, `db/schema.rb`

**Interfaces:**
- Produces: `User#passports`, `Passport.active`, `Passport.pending`, `Passport.ensure_pending_for!(user)`, `Passport#confirm!(presented_token:, actor:)`, `Passport#revoke!(actor:)`, `#active?`, `#pending?`, `#revoked?`.

- [ ] **Step 1: Write failing model specs**

Cover generated unique UUID token, generated `HCP-XXXXXXXX` serial, pending/active/revoked predicates, exact-match confirmation, invalid-state confirmation, staff attribution, idempotent pending creation, multiple active passports per user, and revoking one without touching another.

```ruby
passport = Passport.ensure_pending_for!(owner)
expect(passport.serial_number).to match(/\AHCP-[A-F0-9]{8}\z/)
passport.confirm!(presented_token: passport.token, actor: staff)
expect(passport.reload).to be_active
expect(passport.paired_by).to eq(staff)
```

- [ ] **Step 2: Verify red**

Run: `mise x ruby@3.4.7 -- bundle exec rspec spec/models/passport_spec.rb`

Expected: `uninitialized constant Passport`.

- [ ] **Step 3: Add the passports table and model**

Create a UUID table with required unique UUID `token`, required unique string `serial_number`, required `user_id`, nullable `paired_at`/`paired_by_id`, nullable `revoked_at`/`revoked_by_id`, timestamps, and foreign keys. Generate values before validation:

```ruby
before_validation :set_token, :set_serial_number, on: :create

def set_token
  self.token ||= SecureRandom.uuid
end

def set_serial_number
  self.serial_number ||= "HCP-#{SecureRandom.hex(4).upcase}"
end
```

Use lifecycle guards so only pending passports confirm, revoked passports remain historical, and `ensure_pending_for!` reuses the newest pending record.

- [ ] **Step 4: Protect private tokens**

Add passport audit actions `passport_pair` and `passport_revoke`. Ensure `:token` remains in Rails filtered parameters, and tests prove audit metadata contains the public serial but not `passport.token`.

- [ ] **Step 5: Migrate, verify, and commit**

Run: `mise x ruby@3.4.7 -- bin/rails db:migrate`

Run: `mise x ruby@3.4.7 -- bundle exec rspec spec/models/passport_spec.rb`

Expected: all examples pass.

Commit: `feat: add hack club passports`

---

### Task 3: Global Admin Passport Pairing

**Files:**
- Create: `app/controllers/admin/passports_controller.rb`, `app/javascript/controllers/passport_pairing_controller.js`
- Create: `spec/requests/admin/passports_spec.rb`
- Modify: `config/routes.rb`, `app/controllers/admin/users_controller.rb`, `app/views/admin/users/show.html.erb`
- Test: `spec/requests/admin/users_spec.rb`

**Interfaces:**
- Consumes: `Passport.ensure_pending_for!`, `#confirm!`, and `#revoke!` from Task 2.
- Produces: `POST /admin/users/:user_id/passports`, `POST /admin/users/:user_id/passports/:id/confirm`, and `DELETE /admin/users/:user_id/passports/:id`.

- [ ] **Step 1: Write failing authorization and lifecycle request specs**

Prove global admins can create/reuse pending passports, confirm only an exact token, and revoke an active passport. Prove event admins and ordinary users cannot use any route. Verify JSON creation includes `id`, private `token`, and public `serial_number`; subsequent rendered HTML includes only the serial. Verify audit records target the passport and omit its token.

```ruby
post admin_user_passports_path(owner)
expect(response).to have_http_status(:created)
passport = owner.passports.pending.sole

post confirm_admin_user_passport_path(owner, passport), params: { passport_token: passport.token }
expect(passport.reload).to be_active
```

- [ ] **Step 2: Verify red**

Run: `mise x ruby@3.4.7 -- bundle exec rspec spec/requests/admin/passports_spec.rb spec/requests/admin/users_spec.rb`

Expected: missing routes/controller and missing passport UI.

- [ ] **Step 3: Implement routes and controller**

Nest `resources :passports, only: [:create, :destroy]` under admin users with a member `post :confirm`. Require `current_user.global_admin?`, scope every lookup through `@user.passports`, set `@record = @passport` for automatic auditing, return 422 for mismatches or invalid states, and redirect back to the user for revocation.

- [ ] **Step 4: Add the admin UI and bridge controller**

Render an orange dashed Hack Club Passports section with connection state, pair button, transient status, and passport history. The Stimulus controller connects to `ws://localhost:9876`, creates a pending passport on click, sends `{ action: "write", attend_token: token }`, waits for `write_result`, verifies the second `tag_read.attendToken`, posts the exact token to confirm, clears the token from controller state, and reloads after success. It never puts the private token into HTML, a URL, or console output.

- [ ] **Step 5: Verify green and commit**

Run the Step 2 command.

Expected: all examples pass and response HTML excludes every private token.

Commit: `feat: pair passports from admin user profiles`

---

### Task 4: Participant Passport Profile

**Files:**
- Modify: `app/controllers/dashboard_controller.rb`, `app/views/dashboard/profile.html.erb`
- Create: `spec/requests/dashboard_passports_spec.rb`

**Interfaces:**
- Consumes: `current_user.passports`.
- Produces: data-driven `#passport` navigation and profile section for successfully paired passports.

- [ ] **Step 1: Write failing profile request specs**

Prove no section or navigation appears with no passport or only a pending passport. Prove active and revoked paired passports render their serial number, status, and pairing date while their private tokens and pairing administrator do not render.

```ruby
get dashboard_profile_path
expect(response.body).to include("Hack Club Passport", passport.serial_number, "Active")
expect(response.body).not_to include(passport.token, passport.paired_by.display_name_or_fallback)
```

- [ ] **Step 2: Verify red**

Run: `mise x ruby@3.4.7 -- bundle exec rspec spec/requests/dashboard_passports_spec.rb`

Expected: passport section is absent.

- [ ] **Step 3: Load and render successfully paired passports**

In `DashboardController#profile`, set `@passports = current_user.passports.where.not(paired_at: nil).order(created_at: :desc)`. Render nav and section only when `@passports.any?`, and display only `serial_number`, `active?`/`revoked?`, and `paired_at`.

- [ ] **Step 4: Verify green and commit**

Run the Step 2 command.

Expected: all examples pass.

Commit: `feat: show passports on dashboard profile`

---

### Task 5: Passport Scan Resolution and Universal NFC Reading

**Files:**
- Replace: `app/services/nfc_token_resolver.rb` with `app/services/nfc_token_resolver.rb` using passport semantics
- Modify: `app/controllers/admin/scans_controller.rb`, `app/controllers/api/v1/scans_controller.rb`
- Modify: `app/views/admin/scans/scanner.html.erb`, `config/openapi.yml`
- Replace: `spec/services/nfc_token_resolver_spec.rb`
- Modify: `spec/requests/admin/scans_spec.rb`, `spec/requests/api/v1/scans_spec.rb`

**Interfaces:**
- Produces: `NfcTokenResolver.call(event:, token:) -> ParticipantEvent | nil`.

- [ ] **Step 1: Write failing resolver and request specs**

Cover current-event assigned badge success, cross-event badge rejection, active passport success at two events, pending/revoked/unknown/malformed rejection, owner without a participant, owner without selected-event participation, and current-event badge precedence. For browser and API controllers, prove passport scans create an NFC-source scan even when badge issuance is disabled.

```ruby
expect(described_class.call(event: second_event, token: passport.token))
  .to eq(second_participation)
expect(described_class.call(event: second_event, token: first_participation.nfc_badge_token))
  .to be_nil
```

- [ ] **Step 2: Verify red**

Run: `mise x ruby@3.4.7 -- bundle exec rspec spec/services/nfc_token_resolver_spec.rb spec/requests/admin/scans_spec.rb spec/requests/api/v1/scans_spec.rb`

Expected: the current resolver references `NfcToken` and/or passport scans fail.

- [ ] **Step 3: Implement ordered resolution**

```ruby
def call
  event_badge = event.participant_events
    .where.not(nfc_badge_assigned_at: nil)
    .find_by(nfc_badge_token: token)
  return event_badge if event_badge

  passport = Passport.active.includes(user: :participant).find_by(token: token)
  participant = passport&.user&.participant
  participant && event.participant_events.find_by(participant: participant)
end
```

Both scan controllers call the resolver for `badge_token`, then load their existing medical/dietary/safeguarding associations without changing scan creation or deduplication.

- [ ] **Step 4: Keep reading universal and writing event-scoped**

Render the scanner's bridge connection/read UI and WebSocket logic at every event. Keep the write panel, automatic write-on-check-in, modal write controls, event badge ensure/confirm/reset endpoints, and payloads conditional on `current_event.nfc_badges_enabled?`. Remove the incorrect `nfc_pairing_available` payload and logic.

- [ ] **Step 5: Update documentation and verify**

Document that `badge_token` accepts either an assigned badge for the selected event or an active passport, while all NFC badge provisioning endpoints remain participant-event scoped.

Run: `mise x ruby@3.4.7 -- bundle exec rspec spec/models/passport_spec.rb spec/requests/admin/passports_spec.rb spec/requests/dashboard_passports_spec.rb spec/services/nfc_token_resolver_spec.rb spec/requests/admin/scans_spec.rb spec/requests/api/v1/scans_spec.rb spec/requests/api/v1/nfc_badges_spec.rb spec/requests/api/v1/participants_spec.rb spec/toolboxes/participant_events_toolbox_spec.rb`

Run: `mise x ruby@3.4.7 -- bin/rubocop`

Run: `mise x ruby@3.4.7 -- ruby -e 'require "yaml"; YAML.safe_load_file("config/openapi.yml", aliases: true); puts "openapi ok"'`

Expected: focused specs and RuboCop pass; OpenAPI prints `openapi ok`.

- [ ] **Step 6: Run full verification and commit**

Run: `mise x ruby@3.4.7 -- bundle exec rspec`

Report any pre-existing baseline failures separately from failures introduced by passports.

Commit: `feat: accept passports at every event`
