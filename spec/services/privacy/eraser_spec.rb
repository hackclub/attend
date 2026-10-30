require "rails_helper"

RSpec.describe Privacy::Eraser do
  def subject_for(emails: [], slack_id: nil, identity_id: nil)
    Privacy::Token::Subject.new(emails:, slack_id:, identity_id:)
  end

  let(:past_event) { create(:event, starts_at: 3.weeks.ago, ends_at: 2.weeks.ago, registration_open_at: 2.months.ago, registration_close_at: 1.month.ago) }
  let(:user) { create(:user, email: "attendee@example.com", hack_club_account_id: "ident!fake1", slack_user_id: "U0FAKE1", oidc_claims: { "slack_id" => "U0FAKE1" }) }
  let(:participant) { create(:participant, email: "attendee@example.com", user:, slack_user_id: "U0FAKE1") }
  let!(:registration) { create(:participant_event, participant:, event: past_event, status: :complete) }
  let(:guardian) { create(:guardian, email: "parent@example.com") }
  let!(:guardian_link) { create(:guardian_participant_event, guardian:, participant_event: registration) }

  before do
    Medical.create!(participant_event: registration)
    registration.emergency_contacts.create!(name: "Fictional Contact", phone: "+12025550101", relationship: "aunt")
    participant.headshot.attach(io: file_fixture("headshot.png").open, filename: "headshot.png", content_type: "image/png")
  end

  it "reports found: false when nothing matches" do
    result = described_class.new(subject_for(emails: [ "nobody@example.com" ])).call(dry_run: false)

    expect(result).to have_attributes(found: false, deleted: {}, retained: [])
  end

  it "changes nothing on a dry run" do
    result = described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: true)

    expect(result.found).to be(true)
    expect(Participant.exists?(participant.id)).to be(true)
    expect(User.exists?(user.id)).to be(true)
    expect(Medical.where(participant_event: registration)).to exist
    expect(participant.reload.headshot).to be_attached
  end

  it "reports the same counts on a dry run as on the real run" do
    eraser = described_class.new(subject_for(emails: [ "attendee@example.com" ]))
    dry = eraser.call(dry_run: true)
    real = eraser.call(dry_run: false)

    expect(dry.deleted).to eq(real.deleted)
    expect(real.deleted).to include("users" => 1, "participants" => 1, "participant_events" => 1,
      "guardians" => 1, "medicals" => 1, "emergency_contacts" => 1, "active_storage_attachments" => 1)
  end

  it "erases the attendee, their registration and the guardian who was only there for them" do
    PaperTrail.request(enabled: true) { participant.update!(preferred_name: "Fakey") }

    blob = participant.headshot.blob

    described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false)

    expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
    expect(blob.service.exist?(blob.key)).to be(false)
    expect(User.exists?(user.id)).to be(false)
    expect(Participant.exists?(participant.id)).to be(false)
    expect(ParticipantEvent.exists?(registration.id)).to be(false)
    expect(Guardian.exists?(guardian.id)).to be(false)
    expect(EmergencyContact.where(participant_event_id: registration.id)).not_to exist
    expect(PaperTrail::Version.where(item_id: participant.id)).not_to exist
    expect(ActiveStorage::Attachment.where(record_id: participant.id)).not_to exist
  end

  it "keeps a guardian who still has another child registered" do
    sibling = create(:participant_event, event: past_event)
    create(:guardian_participant_event, guardian:, participant_event: sibling)

    described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false)

    expect(Guardian.exists?(guardian.id)).to be(true)
    expect(guardian.guardian_participant_events.pluck(:participant_event_id)).to eq([ sibling.id ])
  end

  it "matches on the Hack Club identity and Slack ID alone" do
    expect(described_class.new(subject_for(identity_id: "ident!fake1")).call(dry_run: true).found).to be(true)
    expect(described_class.new(subject_for(slack_id: "U0FAKE1")).call(dry_run: true).found).to be(true)
  end

  it "erases a guardian on their own request" do
    guardian.update!(user: create(:user, email: guardian.email, hack_club_account_id: "ident!parent"))
    described_class.new(subject_for(emails: [ "parent@example.com" ])).call(dry_run: false)

    expect(Guardian.exists?(guardian.id)).to be(false)
    expect(Participant.exists?(participant.id)).to be(true)
  end

  it "reports signed and unsigned DocuSeal documents as retained, separately" do
    registration.consents.create!(consent_type: "waiver", status: "signed", docuseal_envelope_id: "fake-envelope")
    registration.consents.create!(consent_type: "media", status: "sent", docuseal_envelope_id: "fake-envelope-2")

    result = described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: true)

    expect(result.retained).to include(a_hash_including(type: "signed documents", count: 1),
      a_hash_including(type: "unsigned documents", count: 1))
  end

  it "erases their MCP grants and tokens" do
    application = Toolchest::OauthApplication.create!(name: "Fictional client", redirect_uri: "https://example.com/callback")
    settings = McpConnectionSetting.create!(application:, resource_owner_id: user.id)
    connection_event = settings.mcp_connection_events.create!(event: past_event)
    settings.update!(all_events: false)
    other_settings = McpConnectionSetting.create!(application:, resource_owner_id: create(:user).id)

    eraser = described_class.new(subject_for(emails: [ "attendee@example.com" ]))
    dry = eraser.call(dry_run: true)
    expect(McpConnectionSetting.exists?(settings.id)).to be(true)
    expect(McpConnectionEvent.exists?(connection_event.id)).to be(true)

    result = eraser.call(dry_run: false)

    expect(result.deleted).to eq(dry.deleted)
    expect(result.deleted).to include("mcp_connection_settings" => 1, "mcp_connection_events" => 1)
    expect(McpConnectionSetting.where(resource_owner_id: user.id)).not_to exist
    expect(McpConnectionEvent.exists?(connection_event.id)).to be(false)
    expect(McpConnectionSetting.exists?(other_settings.id)).to be(true)
    expect(User.exists?(user.id)).to be(false)
  end

  # schema.rb no longer has these, but a database loaded from an older one can
  it "erases their rows in the leftover hospitality and NFC token tables where those are still there" do
    connection = ActiveRecord::Base.connection
    %i[hospitality_acts hospitality_redemptions nfc_tokens].each do |table|
      connection.create_table(table, id: :uuid) do |t|
        t.uuid :user_id
        t.uuid :participant_event_id if table == :hospitality_acts
      end
    end
    other_user = create(:user)
    insert = ->(sql, *binds) { connection.execute(ActiveRecord::Base.sanitize_sql([ sql, *binds ])) }
    insert.("INSERT INTO hospitality_acts (participant_event_id) VALUES (?)", registration.id)
    insert.("INSERT INTO hospitality_acts (user_id) VALUES (?), (?)", user.id, other_user.id)
    insert.("INSERT INTO hospitality_redemptions (user_id) VALUES (?), (?)", user.id, other_user.id)
    insert.("INSERT INTO nfc_tokens (user_id) VALUES (?), (?)", user.id, other_user.id)

    eraser = described_class.new(subject_for(emails: [ "attendee@example.com" ]))
    dry = eraser.call(dry_run: true)
    result = eraser.call(dry_run: false)

    expect(result.deleted).to eq(dry.deleted)
    expect(result.deleted).to include("hospitality_acts" => 2, "hospitality_redemptions" => 1, "nfc_tokens" => 1)
    %w[hospitality_acts hospitality_redemptions nfc_tokens].each do |table|
      expect(connection.select_values("SELECT user_id FROM #{table}")).to eq([ other_user.id ])
    end
  end

  describe "attachment files" do
    let(:blob) { participant.headshot.blob }

    it "leaves files alone on a dry run" do
      described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: true)

      expect(blob.service.exist?(blob.key)).to be(true)
    end

    it "rolls everything back when storage fails, so the retry still finds them and finishes" do
      allow_any_instance_of(ActiveStorage::Blob).to receive(:delete).and_raise(Errno::ECONNRESET)

      expect { described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false) }
        .to raise_error(described_class::Unavailable) { |error| expect(error.code).to eq("storage_unavailable") }
      expect(Participant.exists?(participant.id)).to be(true)
      expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)

      allow_any_instance_of(ActiveStorage::Blob).to receive(:delete).and_call_original
      retry_result = described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false)

      expect(retry_result.found).to be(true)
      expect(Participant.exists?(participant.id)).to be(false)
      expect(blob.service.exist?(blob.key)).to be(false)
    end

    it "deletes variants with the original" do
      variant = participant.headshot.variant(resize_to_limit: [ 10, 10 ]).processed
      variant_blob = variant.image.blob

      described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false)

      expect(ActiveStorage::VariantRecord.where(blob_id: blob.id)).not_to exist
      expect(ActiveStorage::Blob.exists?(variant_blob.id)).to be(false)
      expect(variant_blob.service.exist?(variant_blob.key)).to be(false)
    end
  end

  describe "import batches" do
    def row(email, **fields) = { "email" => email, "legal_first_name" => "Fictional" }.merge(fields.transform_keys(&:to_s))

    it "finds and removes someone who only exists in an import preview" do
      batch = ImportBatch.create!(event: past_event, status: :previewing, total_count: 2,
        rows_data: [ row("preview-only@example.com"), row("someone-else@example.com") ])

      result = described_class.new(subject_for(emails: [ "preview-only@example.com" ])).call(dry_run: false)

      expect(result.found).to be(true)
      expect(result.deleted).to include("import_batches.rows_data" => 1)
      expect(batch.reload.rows_data.map { |r| r["email"] }).to eq([ "someone-else@example.com" ])
    end

    it "matches an import-only Slack ID without expanding to the row's typed email" do
      matched = row("old-address@example.com", slack_id: "U0IMPORT")
      other = row("old-address@example.com", slack_id: "U0OTHER")
      batch = ImportBatch.create!(event: past_event, status: :previewing, total_count: 2, rows_data: [ matched, other ])
      invitation = create(:invitation, event: past_event, email: "old-address@example.com")
      eraser = described_class.new(subject_for(slack_id: "U0IMPORT"))

      dry = eraser.call(dry_run: true)
      expect(dry.found).to be(true)
      expect(batch.reload.rows_data).to eq([ matched, other ])

      real = eraser.call(dry_run: false)

      expect(real.deleted).to eq(dry.deleted)
      expect(real.deleted).to include("import_batches.rows_data" => 1)
      expect(batch.reload.rows_data).to eq([ other ])
      expect(Invitation.exists?(invitation.id)).to be(true)
    end

    it "needs a human when an import matched only on Slack is running" do
      batch = ImportBatch.create!(event: past_event, status: :importing, total_count: 1,
        rows_data: [ row("old-address@example.com", slack_id: "U0IMPORT") ])

      expect { described_class.new(subject_for(slack_id: "U0IMPORT")).call(dry_run: false) }
        .to raise_error(described_class::ManualReviewRequired) { |error| expect(error.reason).to eq("import_in_progress") }
      expect(batch.reload.rows_data.size).to eq(1)
    end

    it "removes their errors from a finished batch, and only theirs" do
      batch = ImportBatch.create!(event: past_event, status: :completed, total_count: 2, errors_data: [
        { "row" => 2, "email" => "attendee@example.com", "error" => "Already registered for this event" },
        { "row" => nil, "email" => nil, "error" => "Failed to send invitation for attendee@example.com" },
        { "row" => 3, "email" => "someone-else@example.com", "error" => "Already registered for this event" }
      ])

      result = described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false)

      expect(result.deleted).to include("import_batches.errors_data" => 2)
      expect(batch.reload.errors_data.map { |e| e["email"] }).to eq([ "someone-else@example.com" ])
    end

    it "takes a parent or emergency contact's details off another child's row, leaving the child's" do
      guardian.update!(user: create(:user, email: guardian.email, hack_club_account_id: "ident!parent"))
      batch = ImportBatch.create!(event: past_event, status: :previewing, total_count: 1, rows_data: [
        row("child@example.com", parent_first_name: "Fictional", parent_email: "parent@example.com", parent_phone: "+12025550111",
          emergency_first_name: "Fictional", emergency_email: "parent@example.com", medical_requirements: "fictional")
      ])
      create(:guardian_participant_event, guardian:, participant_event: create(:participant_event, event: past_event))

      described_class.new(subject_for(emails: [ "parent@example.com" ])).call(dry_run: false)

      kept = batch.reload.rows_data.first
      expect(kept).to include("email" => "child@example.com", "medical_requirements" => "fictional")
      expect(kept.keys).not_to include("parent_email", "parent_phone", "parent_first_name", "emergency_email", "emergency_first_name")
    end

    it "changes nothing on a dry run" do
      batch = ImportBatch.create!(event: past_event, status: :previewing, total_count: 1, rows_data: [ row("attendee@example.com") ])

      described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: true)

      expect(batch.reload.rows_data.size).to eq(1)
    end

    it "needs a human while an import holding them is running" do
      ImportBatch.create!(event: past_event, status: :importing, total_count: 1, rows_data: [ row("attendee@example.com") ])

      expect { described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false) }
        .to raise_error(described_class::ManualReviewRequired) { |error| expect(error.reason).to eq("import_in_progress") }
      expect(Participant.exists?(participant.id)).to be(true)
    end
  end

  it "keeps a consent the guardian signed for a child who stays, with its uploads" do
    guardian.update!(user: create(:user, email: guardian.email, hack_club_account_id: "ident!parent"))
    consent = registration.consents.create!(consent_type: "waiver", status: "signed", guardian_participant_event: guardian_link,
      docuseal_envelope_id: "fake-envelope", docuseal_guardian_slug: "fake-guardian-slug", docuseal_participant_slug: "fake-participant-slug")
    consent.physical_uploads.attach(io: file_fixture("headshot.png").open, filename: "signed.png", content_type: "image/png")
    PaperTrail.request(enabled: true) do
      consent.update!(failure_reason: "fictional")
      consent.update!(docuseal_guardian_slug: "fake-guardian-slug-2")
    end

    result = described_class.new(subject_for(emails: [ "parent@example.com" ])).call(dry_run: false)

    expect(Guardian.exists?(guardian.id)).to be(false)
    expect(consent.reload).to have_attributes(guardian_participant_event_id: nil, status: "signed",
      docuseal_guardian_slug: nil, docuseal_participant_slug: "fake-participant-slug")
    expect(consent.physical_uploads).to be_attached
    expect(result.retained).to include(a_hash_including(type: "guardian-signed documents", count: 1))
    history = PaperTrail::Version.where(item_id: consent.id).pluck(:object, :object_changes).flatten.compact.join
    expect(history).not_to include("fake-guardian-slug", guardian_link.id)
    expect(history).to include("fictional", "fake-participant-slug")
  end

  it "erases every profile on an account matched on its Hack Club identity" do
    user.update!(email: "account@example.com")
    other_profile = create(:participant, email: "old-address@example.com", user:)

    described_class.new(subject_for(emails: [ "attendee@example.com" ], identity_id: "ident!fake1")).call(dry_run: false)

    expect(User.exists?(user.id)).to be(false)
    expect(Participant.exists?(other_profile.id)).to be(false)
  end

  it "erases the account behind a Slack ID Hack Club Auth vouches for" do
    described_class.new(subject_for(slack_id: "U0FAKE1")).call(dry_run: false)

    expect(Participant.exists?(participant.id)).to be(false)
    expect(User.exists?(user.id)).to be(false)
  end

  it "erases an account that other people's audit entries name as the actor" do
    AuditLog.create!(actor_user_id: user.id, action: "update", record_type: "Event", record_id: past_event.id)

    described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false)

    expect(User.exists?(user.id)).to be(false)
    expect(AuditLog.where(record_id: past_event.id).pluck(:actor_user_id)).to eq([ nil ])
  end

  describe "matching only the subject" do
    def expect_conflict(subject)
      expect { described_class.new(subject).call(dry_run: false) }
        .to raise_error(described_class::ManualReviewRequired) { |error| expect(error.reason).to eq("identity_conflict") }
    end

    %i[participant guardian].each do |profile|
      it "does not expand email searches through an erased #{profile}'s editable email" do
        bob = create(:user, email: "bob@example.com", hack_club_account_id: "ident!bob")
        bob_profile = create(:participant, email: bob.email, user: bob)
        bob_registration = create(:participant_event, participant: bob_profile, event: past_event)
        public_send(profile).update!(email: bob.email)
        invitation = create(:invitation, event: past_event, email: bob.email)
        email_log = create(:email_log, to_address: bob.email)
        linked_log = create(:email_log, to_address: bob.email, emailable: public_send(profile))
        message = Message.create!(event: past_event, sent_by_user: bob, audience: "all_attendees", channels: [ "email" ], body: "Fictional")
        delivery = message.message_deliveries.create!(participant_event: bob_registration, channel: "email", recipient_email: bob.email)
        rows = [ { "email" => bob.email, "legal_first_name" => "Fictional Bob" } ]
        batch = ImportBatch.create!(event: past_event, status: :previewing, total_count: 1, rows_data: rows)

        described_class.new(subject_for(emails: [ "attendee@example.com" ], identity_id: "ident!fake1")).call(dry_run: false)

        expect(User.exists?(user.id)).to be(false)
        expect(User.exists?(bob.id)).to be(true)
        expect(Participant.exists?(bob_profile.id)).to be(true)
        expect(Invitation.exists?(invitation.id)).to be(true)
        expect(EmailLog.exists?(email_log.id)).to be(true)
        expect(EmailLog.exists?(linked_log.id)).to be(false)
        expect(MessageDelivery.exists?(delivery.id)).to be(true)
        expect(batch.reload.rows_data).to eq(rows)
      end
    end

    [ nil, "U0OVERRIDE" ].each do |override|
      it "matches the verified Slack ID when the editable override is #{override.inspect}" do
        user.update!(slack_user_id: override)
        eraser = described_class.new(subject_for(slack_id: "U0FAKE1"))

        dry = eraser.call(dry_run: true)
        expect(dry.found).to be(true)
        expect(User.exists?(user.id)).to be(true)

        real = eraser.call(dry_run: false)

        expect(real.deleted).to eq(dry.deleted)
        expect(User.exists?(user.id)).to be(false)
        expect(Participant.exists?(participant.id)).to be(false)
      end
    end

    # Alice's profile carries Bob's email; Bob asks to be erased
    it "stops when a profile's typed email leads to someone else's account" do
      bob = create(:user, email: "bob@example.com", hack_club_account_id: "ident!bob")
      create(:participant, email: "bob@example.com", user: bob)
      alice = create(:user, email: "alice@example.com", hack_club_account_id: "ident!alice")
      alice_profile = create(:participant, email: "alice-typed@example.com", user: alice)
      alice_profile.update_columns(email: "bob@example.com")

      expect_conflict(subject_for(emails: [ "bob@example.com" ], identity_id: "ident!bob"))
      expect(User.exists?(alice.id)).to be(true)
      expect(Participant.exists?(alice_profile.id)).to be(true)
      expect(User.exists?(bob.id)).to be(true)
    end

    it "stops when an email leads to an account with a different Hack Club identity" do
      expect_conflict(subject_for(emails: [ "attendee@example.com" ], identity_id: "ident!someone-else"))
      expect(User.exists?(user.id)).to be(true)
    end

    it "stops on a Slack ID typed onto someone else's profile override" do
      user.update!(oidc_claims: { "slack_id" => "U0REAL1" })

      expect_conflict(subject_for(slack_id: "U0FAKE1"))
      expect(User.exists?(user.id)).to be(true)
    end

    it "stops on a standalone profile's editable Slack ID, even if another account vouches for that ID" do
      imported = create(:participant, email: "someone-else@example.com", slack_user_id: "U0FAKE1")
      imported_registration = create(:participant_event, participant: imported, event: past_event)

      expect_conflict(subject_for(slack_id: "U0FAKE1"))
      expect(Participant.exists?(imported.id)).to be(true)
      expect(ParticipantEvent.exists?(imported_registration.id)).to be(true)
      expect(User.exists?(user.id)).to be(true)
    end

    it "stops on a standalone profile's Slack ID when no HCA account matches" do
      participant.update!(user: nil)
      user.update!(oidc_claims: {})

      expect_conflict(subject_for(slack_id: "U0FAKE1"))
      expect(Participant.exists?(participant.id)).to be(true)
      expect(ParticipantEvent.exists?(registration.id)).to be(true)
    end

    it "allows an unclaimed profile independently matched on its email as well as its Slack ID" do
      imported = create(:participant, email: "imported@example.com", slack_user_id: "U0IMPORTED")

      described_class.new(subject_for(emails: [ imported.email ], slack_id: imported.slack_user_id)).call(dry_run: false)

      expect(Participant.exists?(imported.id)).to be(false)
    end

    it "stops on a placeholder's email after its staff role was removed" do
      placeholder = create(:user, email: "placeholder@example.com", global_role: :global_admin)
      placeholder.update!(global_role: :no_role)
      profile = create(:participant, email: placeholder.email, user: placeholder)

      expect_conflict(subject_for(emails: [ placeholder.email ], identity_id: "ident!unproven"))
      expect(User.exists?(placeholder.id)).to be(true)
      expect(Participant.exists?(profile.id)).to be(true)
    end

    it "allows an account without an identity ID when its HCA Slack claim matches" do
      user.update!(hack_club_account_id: nil)

      described_class.new(subject_for(emails: [ user.email ], slack_id: "U0FAKE1")).call(dry_run: false)

      expect(User.exists?(user.id)).to be(false)
    end

    it "stops on a Slack ID typed onto someone else's registration" do
      participant.update!(slack_user_id: nil)
      user.update!(slack_user_id: nil, oidc_claims: {})
      registration.update!(slack_user_id: "U0TYPO1")

      expect_conflict(subject_for(slack_id: "U0TYPO1"))
      expect(Participant.exists?(participant.id)).to be(true)
      expect(User.exists?(user.id)).to be(true)
    end

    it "stops when a guardian matched on email belongs to another account" do
      guardian.update!(user: create(:user, email: "parent-account@example.com"))

      expect_conflict(subject_for(emails: [ "parent@example.com" ]))
      expect(Guardian.exists?(guardian.id)).to be(true)
    end

    it "stops when a standalone guardian is matched only on an editable email" do
      expect_conflict(subject_for(emails: [ guardian.email ]))

      expect(Guardian.exists?(guardian.id)).to be(true)
      expect(GuardianParticipantEvent.exists?(guardian_link.id)).to be(true)
      expect(ParticipantEvent.exists?(registration.id)).to be(true)
    end

    it "erases an imported profile no account has claimed, matched on its email" do
      imported = create(:participant, email: "imported@example.com")

      described_class.new(subject_for(emails: [ "imported@example.com" ])).call(dry_run: false)

      expect(Participant.exists?(imported.id)).to be(false)
    end

    it "leaves blank-email rows alone when the hub sends no emails" do
      other = create(:participant_event, event: past_event)
      blank = other.emergency_contacts.create!(name: "Fictional Contact", phone: "+12025550102", email: "")

      result = described_class.new(subject_for(slack_id: "U0NOBODY")).call(dry_run: false)

      expect(result.found).to be(false)
      expect(EmergencyContact.exists?(blank.id)).to be(true)
    end

    it "keeps texts and tickets from a phone number someone staying on file shares" do
      parent = create(:guardian, phone: participant.phone)
      create(:guardian_participant_event, guardian: parent, participant_event: create(:participant_event, event: past_event))
      ticket = Ticket.create!(channel: "sms", phone_number: participant.phone)
      sms = AutomatedSmsLog.create!(phone_number: participant.phone, body: "fictional", source: "spec", sent_at: Time.current)

      described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false)

      expect(Ticket.exists?(ticket.id)).to be(true)
      expect(AutomatedSmsLog.exists?(sms.id)).to be(true)
      expect(Guardian.exists?(parent.id)).to be(true)
    end

    it "keeps tickets from a phone number another account shares" do
      create(:user, phone_number: participant.phone)
      ticket = Ticket.create!(channel: "sms", phone_number: participant.phone)

      described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false)

      expect(Ticket.exists?(ticket.id)).to be(true)
    end

    it "erases texts and unfiled tickets from a number only they had" do
      participant.update!(phone: "+12025550177")
      ticket = Ticket.create!(channel: "sms", phone_number: "+12025550177")

      described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false)

      expect(Ticket.exists?(ticket.id)).to be(false)
    end
  end

  describe "manual review" do
    def expect_review(reason, emails: [ "attendee@example.com" ])
      expect { described_class.new(subject_for(emails:)).call(dry_run: false) }
        .to raise_error(described_class::ManualReviewRequired) { |error| expect(error.reason).to eq(reason) }
      expect(Participant.exists?(participant.id)).to be(true)
    end

    it "is needed for staff accounts" do
      create(:event_role_assignment, user:, event: past_event)

      expect_review("staff_account")
    end

    it "is needed while a registration's event hasn't ended" do
      create(:participant_event, participant:, event: create(:event))

      expect_review("event_not_over")
    end

    it "is needed for an event that started but has no end time" do
      past_event.update!(ends_at: nil)

      expect(past_event.phase_at).to eq(:live)
      expect_review("event_not_over")
    end

    it "allows erasure exactly when the event ends" do
      expect(described_class.new(subject_for(emails: [ user.email ]), now: past_event.ends_at).call(dry_run: true).found).to be(true)
    end

    it "is needed when the guardian has a child at an event still to come" do
      guardian.update!(user: create(:user, email: guardian.email, hack_club_account_id: "ident!parent"))
      create(:guardian_participant_event, guardian:, participant_event: create(:participant_event, event: create(:event)))

      expect_review("event_not_over", emails: [ "parent@example.com" ])
    end

    it "is needed when they're named in a safeguarding incident" do
      Incident.create!(event: past_event, participant_event: registration, reported_by_user_id: create(:user).id,
        category: :safeguarding, severity: Incident.severities.keys.first, summary: "fictional")

      expect_review("safeguarding_record")
    end

    %w[pending upheld].each do |status|
      it "preserves a safety disclosure marked #{status} and its eligibility restriction" do
        disclosure = TrainingDisclosure.create!(user:, question: "Fictional declaration", answer: "yes",
          review_status: status, review_note: "Fictional review")

        expect_review("safeguarding_record")

        expect(TrainingDisclosure.exists?(disclosure.id)).to be(true)
        expect(user.reload.eligible_to_work_events?).to be(false)
      end
    end

    it "is needed for a banned address" do
      Ban.create!(reason: "fictional", ban_emails: [ BanEmail.new(email: "attendee@example.com") ])

      expect_review("banned")
    end

    it "is skipped for exports, which only ever run dry" do
      create(:participant_event, participant:, event: create(:event))

      expect(described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: true, review: false).found).to be(true)
    end
  end

  it "erases dependent training and volunteer history, with identical dry-run counts" do
    records = PaperTrail.request(enabled: true) do
      enrollment = create(:training_enrollment, user:)
      [ enrollment,
        create(:training_badge_award, user:),
        TrainingCourseInvitation.create!(user:, course: enrollment.course),
        TrainingDisclosure.create!(user:, enrollment:, question: "Fictional declaration", answer: "no"),
        TrainingDisclosure.create!(user:, question: "Fictional declaration", answer: "yes", review_status: "cleared", review_note: "Cleared"),
        create(:event_volunteer, user:, event: past_event) ]
    end
    ids = records.map(&:id)
    records.each { |record| AuditLog.log!(action: "create", record:) }
    other = PaperTrail.request(enabled: true) { create(:training_enrollment) }
    AuditLog.log!(action: "create", record: other)
    expect(PaperTrail::Version.where(item_id: ids).distinct.pluck(:item_id)).to match_array(ids)
    eraser = described_class.new(subject_for(emails: [ user.email ]))

    dry = eraser.call(dry_run: true)
    records.each { |record| expect(record.class.exists?(record.id)).to be(true) }
    expect(PaperTrail::Version.where(item_id: ids).count).to eq(ids.size)
    expect(AuditLog.where(record_id: ids).count).to eq(ids.size)

    real = eraser.call(dry_run: false)

    expect(real.deleted).to eq(dry.deleted)
    expect(real.deleted).to include("training_enrollments" => 1, "training_badge_awards" => 1,
      "training_course_invitations" => 1, "training_disclosures" => 2, "event_volunteers" => 1)
    records.each { |record| expect(record.class.exists?(record.id)).to be(false) }
    expect(PaperTrail::Version.where(item_id: ids)).not_to exist
    expect(AuditLog.where(record_id: ids)).not_to exist
    expect(TrainingEnrollment.exists?(other.id)).to be(true)
    expect(PaperTrail::Version.where(item_id: other.id)).to exist
    expect(AuditLog.where(record_id: other.id)).to exist
  end

  describe "visa letters" do
    let(:upcoming_event) { create(:event) }

    before { create(:visa_letter_template, :default) }

    def sent_letter(event:, **attributes)
      create(:visa_letter_application, event:, **attributes).tap do |application|
        application.approve!(by: create(:user))
        application.issue_letter!
      end
    end

    it "erases their applications, letters and invitations to apply" do
      application = sent_letter(event: past_event, user:)
      imported = create(:visa_letter_application, :imported, event: create(:event, starts_at: 1.year.ago, ends_at: 1.year.ago + 2.days),
        email: "Attendee@Example.com", status: :rejected, rejection_type: :soft, rejection_reason: "Fictional reason")
      invitation = create(:visa_letter_invitation, event: past_event, email: "attendee@example.com")
      blob = application.letter_pdf.blob
      eraser = described_class.new(subject_for(emails: [ "attendee@example.com" ]))

      dry = eraser.call(dry_run: true)
      expect(VisaLetterApplication.exists?(application.id)).to be(true)

      real = eraser.call(dry_run: false)

      expect(real.deleted).to eq(dry.deleted)
      expect(real.deleted).to include("visa_letter_applications" => 2, "visa_letter_invitations" => 1)
      expect(VisaLetterApplication.where(id: [ application.id, imported.id ])).not_to exist
      expect(VisaLetterInvitation.exists?(invitation.id)).to be(false)
      expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
    end

    it "waits while an application is under review or a letter is for an event still to come" do
      eraser = described_class.new(subject_for(emails: [ "attendee@example.com" ]))
      pending_application = create(:visa_letter_application, event: past_event, user:)

      expect { eraser.call(dry_run: false) }
        .to raise_error(described_class::ManualReviewRequired) { |error| expect(error.reason).to eq("visa_letter_active") }

      pending_application.reject!(by: create(:user), reason: "Fictional reason")
      sent_letter(event: upcoming_event, user: create(:user), email: "attendee@example.com").update_columns(user_id: nil, imported_at: Time.current)

      expect { eraser.call(dry_run: false) }
        .to raise_error(described_class::ManualReviewRequired) { |error| expect(error.reason).to eq("visa_letter_active") }
      expect(eraser.call(dry_run: true, review: false).found).to be(true)
    end

    it "stops on an application with their email that belongs to someone else's account" do
      someone_else = create(:user, email: "someone-else@example.com")
      create(:visa_letter_application, event: past_event, user: someone_else, email: "attendee@example.com")

      expect { described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false) }
        .to raise_error(described_class::ManualReviewRequired) { |error| expect(error.reason).to eq("identity_conflict") }
    end
  end
end
