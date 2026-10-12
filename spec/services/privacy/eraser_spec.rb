require "rails_helper"

RSpec.describe Privacy::Eraser do
  def subject_for(emails: [], slack_id: nil, identity_id: nil)
    Privacy::Token::Subject.new(emails:, slack_id:, identity_id:)
  end

  let(:past_event) { create(:event, starts_at: 3.weeks.ago, ends_at: 2.weeks.ago, registration_open_at: 2.months.ago, registration_close_at: 1.month.ago) }
  let(:user) { create(:user, email: "attendee@example.com", hack_club_account_id: "ident!fake1") }
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

    expect {
      described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: false)
    }.to have_enqueued_job(ActiveStorage::PurgeJob)

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
    described_class.new(subject_for(emails: [ "parent@example.com" ])).call(dry_run: false)

    expect(Guardian.exists?(guardian.id)).to be(false)
    expect(Participant.exists?(participant.id)).to be(true)
  end

  it "reports signed DocuSeal documents as retained" do
    registration.consents.create!(consent_type: "waiver", status: "signed", docuseal_envelope_id: "fake-envelope")

    result = described_class.new(subject_for(emails: [ "attendee@example.com" ])).call(dry_run: true)

    expect(result.retained).to include(a_hash_including(type: "signed documents", count: 1))
  end

  describe "matching only the subject" do
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

    it "is needed when the guardian has a child at an event still to come" do
      create(:guardian_participant_event, guardian:, participant_event: create(:participant_event, event: create(:event)))

      expect_review("event_not_over", emails: [ "parent@example.com" ])
    end

    it "is needed when they're named in a safeguarding incident" do
      Incident.create!(event: past_event, participant_event: registration, reported_by_user_id: create(:user).id,
        category: :safeguarding, severity: :medium, summary: "fictional")

      expect_review("safeguarding_record")
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
end
