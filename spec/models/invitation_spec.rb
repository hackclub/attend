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
end
