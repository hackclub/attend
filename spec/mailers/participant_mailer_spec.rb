require "rails_helper"

RSpec.describe ParticipantMailer, type: :mailer do
  describe "#invitation" do
    it "replies to the event's configured support email" do
      event = create(:event, support_email: "organizers@hackclub.com")

      mail = described_class.invitation(
        email: "participant@example.com",
        event: event
      )

      expect(mail.reply_to).to eq([ "organizers@hackclub.com" ])
    end

    # Resending is the same call twice: the admin's Resend Invitation action
    # relies on the second send reusing the pending invite, so the link the
    # participant already has keeps working.
    it "reuses the pending invitation instead of issuing a new token" do
      event = create(:event)
      participant = create(:participant, email: "resend@example.com")

      first = described_class.invitation(email: participant.email, event: event, participant: participant)
      first.deliver_now
      invitation = event.invitations.pending.sole

      second = described_class.invitation(email: participant.email, event: event, participant: participant)
      second.deliver_now

      expect(event.invitations.pending.pluck(:id)).to eq([ invitation.id ])
      expect(second.body.encoded).to include(invitation.token)
    end

    it "issues a fresh invitation once the old one has expired" do
      event = create(:event)
      participant = create(:participant, email: "expired@example.com")
      stale = Invitation.create!(event: event, email: participant.email)
      stale.update_column(:expires_at, 1.day.ago)

      described_class.invitation(email: participant.email, event: event, participant: participant).deliver_now

      expect(event.invitations.pending.count).to eq(1)
      expect(event.invitations.pending.first.id).not_to eq(stale.id)
    end
  end
end
