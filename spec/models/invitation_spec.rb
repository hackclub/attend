require 'rails_helper'

RSpec.describe Invitation, type: :model do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  describe "held invitations" do
    let(:event) { create(:event) }

    it "stays pending however old it is, because nobody has a link that could expire" do
      held = create(:invitation, event: event, sent_at: nil)
      held.update_columns(created_at: 90.days.ago, expires_at: 60.days.ago)

      expect(Invitation.pending).to include(held)
      expect(Invitation.held).to include(held)
      expect(held).to be_pending
      expect(held).to be_held
    end

    it "is not counted as sent, and an expired sent one is not pending" do
      sent = create(:invitation, event: event, sent_at: 31.days.ago)
      sent.update_column(:expires_at, 1.day.ago)

      expect(Invitation.sent).to include(sent)
      expect(Invitation.held).not_to include(sent)
      expect(Invitation.pending).not_to include(sent)
    end

    it "starts the link's validity window at the first send, and keeps it on resends" do
      held = create(:invitation, event: event, sent_at: nil)
      held.update_column(:expires_at, 1.day.from_now)

      held.mark_sent!
      first_expiry = held.reload.expires_at
      expect(held).to be_sent
      expect(first_expiry).to be_within(1.minute).of(Invitation::LINK_VALIDITY.from_now)

      travel_to(2.days.from_now) { held.mark_sent! }
      expect(held.reload.expires_at).to be_within(1.second).of(first_expiry)
    end
  end

  describe "#withheld?" do
    it "is true for a held invitation while its event is holding onboarding invitations" do
      event = create(:event, onboarding_invites_held: true)

      expect(create(:invitation, event: event, sent_at: nil)).to be_withheld
    end

    it "is false once the invitation has been sent, even while the event holds" do
      event = create(:event, onboarding_invites_held: true)

      expect(create(:invitation, event: event, sent_at: 1.hour.ago)).not_to be_withheld
    end

    it "is false for an unsent invitation on an event that isn't holding" do
      invitation = create(:invitation, event: create(:event, onboarding_invites_held: false), sent_at: nil)

      expect(invitation).to be_held
      expect(invitation).not_to be_withheld
    end
  end

  describe ".issue!" do
    it "records and emails the invitation when the event isn't holding" do
      event = create(:event)

      invitation = nil
      expect {
        invitation = Invitation.issue!(event: event, email: "New@Example.com", name: "New Person")
      }.to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(invitation.email).to eq("new@example.com")
      expect(invitation.name).to eq("New Person")
    end

    it "records without emailing while the event holds onboarding invitations" do
      event = create(:event, onboarding_invites_held: true)

      invitation = nil
      expect {
        invitation = Invitation.issue!(event: event, email: "held@example.com", group_ids: [])
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(invitation).to be_held
      expect(event.invitations.held).to contain_exactly(invitation)
    end

    it "records without emailing when asked for a silent add" do
      event = create(:event)

      expect {
        Invitation.issue!(event: event, email: "quiet@example.com", send: false)
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(event.invitations.held.count).to eq(1)
    end

    it "reuses the held invitation rather than issuing a second token" do
      event = create(:event, onboarding_invites_held: true)
      first = Invitation.issue!(event: event, email: "twice@example.com")

      second = Invitation.issue!(event: event, email: "twice@example.com", name: "Named Later")

      expect(second.id).to eq(first.id)
      expect(second.name).to eq("Named Later")
      expect(event.invitations.count).to eq(1)
    end
  end

  describe "ban enforcement" do
    it "is invalid when the email is on an active ban" do
      create(:ban, email: "banned@example.com")
      invitation = build(:invitation, email: "banned@example.com")

      expect(invitation).not_to be_valid
      expect(invitation.errors[:email]).to include("is banned from events")
    end

    it "is valid when the email is not banned" do
      create(:ban, email: "banned@example.com")
      expect(build(:invitation, email: "allowed@example.com")).to be_valid
    end

    it "is valid when the ban has expired" do
      create(:ban, :expired, email: "banned@example.com")
      expect(build(:invitation, email: "banned@example.com")).to be_valid
    end
  end

  describe ".follow_email_change!" do
    let(:event) { create(:event) }
    let(:participant) { create(:participant, email: "Fern.Old@example.com") }

    def change_email!
      participant.update!(email: "fern.new@example.com")
    end

    before { create(:participant_event, event: event, participant: participant) }

    it "moves held and sent unaccepted invitations to the new address" do
      held = create(:invitation, event: event, email: "fern.old@example.com", sent_at: nil)
      other_event = create(:event)
      create(:participant_event, event: other_event, participant: participant)
      sent = create(:invitation, event: other_event, email: "fern.old@example.com", sent_at: 1.day.ago)
      token = sent.token

      change_email!

      expect(held.reload.email).to eq("fern.new@example.com")
      expect(sent.reload.email).to eq("fern.new@example.com")
      expect(sent.token).to eq(token)
    end

    # An edit made from one event must not redirect another event's invitation.
    it "leaves invitations for events the participant isn't registered at" do
      elsewhere = create(:invitation, event: create(:event), email: "fern.old@example.com", sent_at: nil)

      change_email!

      expect(elsewhere.reload.email).to eq("fern.old@example.com")
    end

    it "leaves accepted invitations where they were sent" do
      accepted = create(:invitation, :accepted, event: event, email: "fern.old@example.com", sent_at: 2.days.ago)

      change_email!

      expect(accepted.reload.email).to eq("fern.old@example.com")
    end

    it "drops the old invitation when the new address already has one for the event" do
      old = create(:invitation, event: event, email: "fern.old@example.com", sent_at: nil)
      existing = create(:invitation, event: event, email: "fern.new@example.com", sent_at: nil)

      change_email!

      expect(Invitation.exists?(old.id)).to be(false)
      expect(event.invitations.held.pluck(:id)).to eq([ existing.id ])
    end

    it "ignores a change of case" do
      invitation = create(:invitation, event: event, email: "fern.old@example.com", sent_at: nil)

      participant.update!(email: "FERN.OLD@example.com")

      expect(invitation.reload.email).to eq("fern.old@example.com")
    end

    # Duplicate participant rows can share an address; the invitation may be
    # the other row's.
    it "moves nothing while another participant still has the old address" do
      participant
      create(:participant, email: "fern.old@example.com")
      invitation = create(:invitation, event: event, email: "fern.old@example.com", sent_at: nil)

      change_email!

      expect(invitation.reload.email).to eq("fern.old@example.com")
    end

    it "keeps the release job and the onboarding gate on the participant's address" do
      event.update!(onboarding_invites_held: true)
      pe = participant.participant_events.sole
      pe.update!(status: :invited)
      create(:invitation, event: event, email: "fern.old@example.com", sent_at: nil)

      change_email!

      expect(event.invitations.held.pluck(:email)).to eq([ "fern.new@example.com" ])
      expect(pe.reload.onboarding_held?).to be(true)
    end
  end
end
