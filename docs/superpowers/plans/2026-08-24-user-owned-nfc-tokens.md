# User-Owned NFC Tokens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace participation-owned NFC issuance with durable user-owned tokens that identify their owner at every event while preserving assigned hardware.

**Architecture:** Store Flipper actor gates and `NfcToken` records in PostgreSQL. Route browser and API scans through one resolver that maps a token to its user's participation in the selected event, with a read-only legacy fallback. Keep `Event#nfc_badges_enabled?` only as the hardware issuance gate while making NFC reading universal.

**Tech Stack:** Rails 8.1, PostgreSQL UUIDs, RSpec, Flipper Active Record, ERB, JavaScript NFC bridge, OpenAPI YAML.

**Spec:** `docs/superpowers/specs/2026-08-24-user-owned-nfc-tokens-design.md`

## Global Constraints

- Tokens are owned by `User`; new flows never mutate participation token columns.
- Every event accepts active personal tokens regardless of `nfc_badges_enabled?`.
- `nfc_badges_enabled?` gates issuance, writing, confirmation, replacement, and revocation only.
- Preserve assigned legacy UUIDs; unlinked legacy participants retain original-event fallback.
- The actor flag is exactly `:personal_nfc_token`; this change adds no participant-facing UI.
- Raw UUIDs do not enter audit metadata or logs.
- Existing mobile paths and response keys remain compatible.

---

### Task 1: Persistent Flipper Actor Flags

**Files:**
- Modify: `Gemfile`, `Gemfile.lock`, `app/models/user.rb`, `spec/models/user_spec.rb`
- Create: `db/migrate/20260824150000_create_flipper_tables.rb`, `config/initializers/flipper.rb`

**Interfaces:**
- Produces: `Flipper.enabled?(:personal_nfc_token, user)` and `User#flipper_id -> String`.

- [ ] **Step 1: Install dependencies and create the official migration**

```bash
bundle add flipper flipper-active_record
bin/rails generate flipper:active_record
```

Use timestamp `20260824150000`. Keep `t.text :value` and both official unique indexes.

- [ ] **Step 2: Apply schema setup**

```bash
bin/rails db:migrate
bin/rails db:test:prepare
```

- [ ] **Step 3: Write failing specs**

Add to `spec/models/user_spec.rb`:

```ruby
describe "Flipper actor identity" do
  it "uses a stable type-qualified id" do
    user = create(:user)
    expect(user.flipper_id).to eq("User;#{user.id}")
  end

  it "persists per-user enablement in Active Record" do
    user = create(:user)
    other = create(:user)
    Flipper.enable_actor(:personal_nfc_token, user)
    expect(Flipper.adapter).to be_a(Flipper::Adapters::ActiveRecord)
    expect(Flipper.enabled?(:personal_nfc_token, user)).to be(true)
    expect(Flipper.enabled?(:personal_nfc_token, other)).to be(false)
  ensure
    Flipper.disable(:personal_nfc_token)
  end
end
```

- [ ] **Step 4: Verify red**

```bash
bundle exec rspec spec/models/user_spec.rb
```

Expected: missing `flipper_id` and/or non-Active Record adapter.

- [ ] **Step 5: Implement the adapter and actor id**

```ruby
# config/initializers/flipper.rb
Flipper.configure do |config|
  config.default { Flipper.new(Flipper::Adapters::ActiveRecord.new) }
end

# app/models/user.rb
def flipper_id
  "User;#{id}"
end
```

- [ ] **Step 6: Verify green and commit**

```bash
bundle exec rspec spec/models/user_spec.rb
git add Gemfile Gemfile.lock config/initializers/flipper.rb db/migrate/20260824150000_create_flipper_tables.rb db/schema.rb app/models/user.rb spec/models/user_spec.rb
git commit -m "feat: install persistent flipper flags"
```

---

### Task 2: User-Owned Token Lifecycle and Backfill

**Files:**
- Create: `db/migrate/20260824150001_create_nfc_tokens.rb`, `db/migrate/20260824150002_backfill_user_owned_nfc_tokens.rb`
- Create: `app/models/nfc_token.rb`, `spec/factories/nfc_tokens.rb`, `spec/models/nfc_token_spec.rb`, `spec/migrations/backfill_user_owned_nfc_tokens_spec.rb`
- Modify: `app/models/user.rb`, `app/models/participant_event.rb`

**Interfaces:**
- Produces: `NfcToken.active`, `.pending`, `.ensure_pending_for!(user)`, `#confirm!`, `#revoke!`, and `User#nfc_tokens`.

- [ ] **Step 1: Write failing lifecycle specs**

Create examples proving a new token is pending, matching confirmation activates it and records staff, mismatch raises `NfcToken::TokenMismatch`, revocation affects one token, pending ensure is idempotent, one user may have two active tokens, and UUIDs are globally unique.

```ruby
token = NfcToken.create!(user: owner)
expect(token).to be_pending
token.confirm!(presented_token: token.token, actor: staff)
expect(token.reload).to be_active
expect(token.paired_by).to eq(staff)
```

- [ ] **Step 2: Verify red**

```bash
bundle exec rspec spec/models/nfc_token_spec.rb
```

Expected: `NfcToken` is undefined.

- [ ] **Step 3: Create and migrate `nfc_tokens`**

Use a UUID primary key, database-generated unique UUID `token`, required `user_id`, optional `paired_at`, `paired_by_id`, `revoked_at`, `revoked_by_id`, timestamps, indexes, and user foreign keys.

```bash
bin/rails db:migrate
bin/rails db:test:prepare
```

- [ ] **Step 4: Implement the minimal lifecycle**

```ruby
class NfcToken < ApplicationRecord
  class TokenMismatch < StandardError; end

  self.implicit_order_column = "created_at"
  belongs_to :user
  belongs_to :paired_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true
  validates :token, presence: true, uniqueness: true
  scope :active, -> { where.not(paired_at: nil).where(revoked_at: nil) }
  scope :pending, -> { where(paired_at: nil, revoked_at: nil) }

  def self.ensure_pending_for!(user)
    user.nfc_tokens.pending.order(created_at: :desc).first || user.nfc_tokens.create!
  end

  def pending? = paired_at.nil? && revoked_at.nil?
  def active? = paired_at.present? && revoked_at.nil?

  def confirm!(presented_token:, actor:)
    raise TokenMismatch unless token == presented_token
    update!(paired_at: Time.current, paired_by: actor)
  end

  def revoke!(actor:)
    update!(revoked_at: Time.current, revoked_by: actor)
  end
end
```

Add `has_many :nfc_tokens, dependent: :destroy` to `User` and an `:active` factory trait.

- [ ] **Step 5: Verify lifecycle green**

```bash
bundle exec rspec spec/models/nfc_token_spec.rb
```

- [ ] **Step 6: Write a failing migration spec**

Require `20260824150002_backfill_user_owned_nfc_tokens.rb`, invoke `BackfillUserOwnedNfcTokens.new.up`, and prove a linked assigned legacy row preserves UUID, owner, assignment time, and assigning staff. Prove an unlinked assigned row remains only in legacy columns.

- [ ] **Step 7: Implement and verify the idempotent SQL backfill**

Insert from `participant_events JOIN participants`, requiring non-null token, assigned time, and participant user id. Preserve the UUID and actor, set timestamps, and use `ON CONFLICT (token) DO NOTHING`. Do not modify legacy columns.

```bash
bundle exec rspec spec/models/nfc_token_spec.rb spec/migrations/backfill_user_owned_nfc_tokens_spec.rb
```

- [ ] **Step 8: Commit**

```bash
git add app/models/nfc_token.rb app/models/user.rb app/models/participant_event.rb spec/factories/nfc_tokens.rb spec/models/nfc_token_spec.rb spec/migrations/backfill_user_owned_nfc_tokens_spec.rb db/migrate/20260824150001_create_nfc_tokens.rb db/migrate/20260824150002_backfill_user_owned_nfc_tokens.rb db/schema.rb
git commit -m "feat: add user-owned nfc tokens"
```

---

### Task 3: Universal Current-Event Resolution

**Files:**
- Create: `app/services/nfc_token_resolver.rb`, `spec/services/nfc_token_resolver_spec.rb`, `spec/requests/admin/scans_spec.rb`
- Modify: `app/controllers/admin/scans_controller.rb`, `app/controllers/api/v1/scans_controller.rb`, `spec/requests/api/v1/scans_spec.rb`
- Modify: `app/toolboxes/participant_events_toolbox.rb`, `spec/toolboxes/participant_events_toolbox_spec.rb`

**Interfaces:**
- Produces: `NfcTokenResolver.call(event:, token:) -> ParticipantEvent | nil`; all authenticated scanners accept active tokens at every event.

- [ ] **Step 1: Write failing resolver specs**

Cover active cross-event resolution, no participation in selected event, pending, revoked, linked legacy cross-event, unlinked legacy original-event only, and unassigned legacy rejection. The revoked case must also have a matching legacy row to prove revocation cannot fall through.

- [ ] **Step 2: Verify red**

```bash
bundle exec rspec spec/services/nfc_token_resolver_spec.rb
```

- [ ] **Step 3: Implement the resolver**

```ruby
class NfcTokenResolver
  def self.call(event:, token:) = new(event: event, token: token).call

  def call
    personal_token = NfcToken.includes(user: :participant).find_by(token: token)
    return participation_for(personal_token.user.participant) if personal_token&.active?
    return nil if personal_token

    legacy = ParticipantEvent.includes(participant: :user).find_by(nfc_badge_token: token)
    return nil unless legacy&.nfc_badge_assigned_at?

    linked_participant = legacy.participant.user&.participant
    return participation_for(linked_participant) if linked_participant

    legacy if legacy.event_id == event.id
  end

  private

  attr_reader :event, :token

  def initialize(event:, token:)
    @event = event
    @token = token
  end

  def participation_for(participant)
    participant&.participant_events&.find_by(event: event)
  end
end
```

- [ ] **Step 4: Verify resolver green**

```bash
bundle exec rspec spec/services/nfc_token_resolver_spec.rb
```

- [ ] **Step 5: Write failing browser and API request specs**

For both controllers, prove a token owned by a participant at two events creates a `source: "nfc"` scan on the requested event when `nfc_badges_enabled` is false. Prove revoked and out-of-event tokens return 404 and create no scan.

- [ ] **Step 6: Verify controller red**

```bash
bundle exec rspec spec/requests/api/v1/scans_spec.rb spec/requests/admin/scans_spec.rb
```

- [ ] **Step 7: Use the resolver and remove implicit legacy token generation**

Replace both event-scoped token lookups with `NfcTokenResolver.call(event:, token:)`, then eager-load the resolved participation's participant/medical/dietary data. Remove both first-check-in calls to `ensure_nfc_badge_token!`. Remove the toolbox call too and change its spec to prove check-in does not create a user token.

- [ ] **Step 8: Verify and commit**

```bash
bundle exec rspec spec/services/nfc_token_resolver_spec.rb spec/requests/api/v1/scans_spec.rb spec/requests/admin/scans_spec.rb spec/toolboxes/participant_events_toolbox_spec.rb
git add app/services/nfc_token_resolver.rb app/controllers/admin/scans_controller.rb app/controllers/api/v1/scans_controller.rb app/toolboxes/participant_events_toolbox.rb spec/services/nfc_token_resolver_spec.rb spec/requests/admin/scans_spec.rb spec/requests/api/v1/scans_spec.rb spec/toolboxes/participant_events_toolbox_spec.rb
git commit -m "feat: resolve nfc tokens across events"
```

---

### Task 4: User-Owned Issuance and Compatible Payloads

**Files:**
- Modify: `app/controllers/admin/participant_events_controller.rb`, `app/controllers/api/v1/nfc_badges_controller.rb`
- Modify: `app/controllers/api/v1/participants_controller.rb`, `app/controllers/api/v1/scans_controller.rb`, `app/controllers/admin/scans_controller.rb`
- Modify: `app/models/participant_event.rb`, `app/models/audit_log.rb`
- Create: `spec/requests/api/v1/nfc_badges_spec.rb`, `spec/requests/admin/nfc_badges_spec.rb`
- Modify: `spec/requests/api/v1/participants_spec.rb`

**Interfaces:**
- Produces: existing ensure/confirm/reset routes backed by user tokens; payload fields `nfc_badge_token`, `nfc_badge_assigned`, and `nfc_pairing_available`.

- [ ] **Step 1: Write failing issuance request specs**

For API and admin routes, prove ensure creates/reuses the linked user's pending token; confirm matches it and records staff; mismatch fails; disabled issuance and unlinked participant fail; reset creates a fresh pending token without revoking active tokens; audit records target `NfcToken` and exclude raw UUID metadata.

- [ ] **Step 2: Verify red**

```bash
bundle exec rspec spec/requests/api/v1/nfc_badges_spec.rb spec/requests/admin/nfc_badges_spec.rb
```

- [ ] **Step 3: Move both controllers to the linked user**

Load `participant: :user`. Return 422 with `Participant must have a linked Attend account before pairing a personal NFC token` when absent. Ensure uses `NfcToken.ensure_pending_for!`; confirm finds the user's matching pending record and calls `confirm!`; reset creates a fresh pending record without revoking active ones. Keep the event issuance check. Audit the token record with participant name and token-record id, never the UUID.

- [ ] **Step 4: Write failing payload specs**

Replace the participation-token GET assertion with examples proving an existing pending user token is returned without writes, an active token sets assigned state, a non-issuing event hides pending issuance data, and an unlinked participant reports pairing unavailable.

- [ ] **Step 5: Implement read-only compatibility payloads**

For the browser scan, API scan, and participant serializers use:

```ruby
user = participant.user
pending_token = user&.nfc_tokens&.pending&.order(created_at: :desc)&.first

{
  nfc_badge_token: event.nfc_badges_enabled? ? pending_token&.token : nil,
  nfc_badge_assigned: user&.nfc_tokens&.active&.exists? || false,
  nfc_pairing_available: user.present?
}
```

Eager-load user/tokens in collection payloads. Make `ParticipantEvent#nfc_badge_assigned?` prefer active user tokens, then assigned legacy state. Keep legacy mutator definitions with deprecation comments but no callers.

- [ ] **Step 6: Verify no legacy mutator callers and run specs**

```bash
rg -n "ensure_nfc_badge_token!|assign_nfc_badge!|reset_nfc_badge!" app --glob '*.rb'
bundle exec rspec spec/requests/api/v1/nfc_badges_spec.rb spec/requests/admin/nfc_badges_spec.rb spec/requests/api/v1/participants_spec.rb spec/requests/api/v1/scans_spec.rb spec/requests/admin/scans_spec.rb
```

Expected: only definitions remain; all specs pass.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/admin/participant_events_controller.rb app/controllers/api/v1/nfc_badges_controller.rb app/controllers/api/v1/participants_controller.rb app/controllers/api/v1/scans_controller.rb app/controllers/admin/scans_controller.rb app/models/participant_event.rb app/models/audit_log.rb spec/requests/api/v1/nfc_badges_spec.rb spec/requests/admin/nfc_badges_spec.rb spec/requests/api/v1/participants_spec.rb
git commit -m "feat: issue nfc tokens to users"
```

---

### Task 5: Universal Reader UI and API Contract

**Files:**
- Modify: `app/views/admin/scans/scanner.html.erb`, `config/openapi.yml`, `spec/requests/docs_spec.rb`
- Create: `spec/requests/admin/scanner_spec.rb`

**Interfaces:**
- Produces: universal read UI, conditional write UI, and documented user ownership.

- [ ] **Step 1: Write failing visibility specs**

Authenticate a global admin against issuing and non-issuing events. Both responses must include `NFC Scanner`, `Connect`, `processNfcScan`, and `ws://localhost:9876`; only the issuing response includes `Write NFC Badge`, `modal-write-nfc-btn`, and enabled write-on-check-in state.

- [ ] **Step 2: Verify red**

```bash
bundle exec rspec spec/requests/admin/scanner_spec.rb
```

- [ ] **Step 3: Split universal reads from gated writes**

Render connection/read status and bridge JavaScript for every event. Keep the write panel/modal controls inside the event flag. Set:

```javascript
const nfcIssuanceEnabled = <%= current_event.nfc_badges_enabled? %>;
const nfcWriteOnCheckin = nfcIssuanceEnabled && <%= current_event.nfc_badge_write_on_checkin_enabled? %>;
```

Normal tag reads always call `processNfcScan`; write handlers require issuance. Auto-write requires `nfc_pairing_available` and calls ensure before opening the panel. Remove the Slack-id requirement for the Attend token; include `badge_url` only when Slack id exists. Copy must distinguish scanning existing personal tokens from issuing event badges.

- [ ] **Step 4: Verify scanner and CSP behavior**

```bash
bundle exec rspec spec/requests/admin/scanner_spec.rb spec/requests/content_security_policy_spec.rb
```

- [ ] **Step 5: Update and test OpenAPI**

Describe scan acceptance as universal, issuance as flag-gated, and ownership as the linked user. Keep existing paths and keys. Extend `spec/requests/docs_spec.rb` to parse YAML and assert NFC paths and `badge_token` fields remain.

```bash
bundle exec rspec spec/requests/docs_spec.rb
```

- [ ] **Step 6: Commit**

```bash
git add app/views/admin/scans/scanner.html.erb spec/requests/admin/scanner_spec.rb config/openapi.yml spec/requests/docs_spec.rb
git commit -m "feat: accept personal nfc tokens at every event"
```

---

### Task 6: Full Verification

**Files:**
- Modify only previously listed files if verification reveals defects.

**Interfaces:**
- Produces: migration-clean, lint-clean, fully tested implementation.

- [ ] **Step 1: Run focused verification**

```bash
bundle exec rspec spec/models/nfc_token_spec.rb spec/models/user_spec.rb spec/migrations/backfill_user_owned_nfc_tokens_spec.rb spec/services/nfc_token_resolver_spec.rb spec/requests/admin/scans_spec.rb spec/requests/admin/scanner_spec.rb spec/requests/admin/nfc_badges_spec.rb spec/requests/api/v1/scans_spec.rb spec/requests/api/v1/nfc_badges_spec.rb spec/requests/api/v1/participants_spec.rb spec/toolboxes/participant_events_toolbox_spec.rb spec/requests/docs_spec.rb spec/requests/content_security_policy_spec.rb
```

- [ ] **Step 2: Run lint and the full suite**

```bash
bin/rubocop
bundle exec rspec
```

- [ ] **Step 3: Check invariants and leakage**

```bash
bin/rails db:migrate:status
rg -n "ensure_nfc_badge_token!|assign_nfc_badge!|reset_nfc_badge!" app --glob '*.rb'
rg -n "badge_token|nfc_badge_token|personal_nfc_token" app config spec
git diff --check
```

Expected: migrations are up; legacy mutators have definitions only; raw tokens occur only in authenticated payload code/tests; participant-facing views contain no feature mention.

- [ ] **Step 4: Commit verification fixes if any**

```bash
git add -u
git commit -m "fix: complete nfc token rollout verification"
```

Skip only when verification changed no files.
