require "rails_helper"

RSpec.describe GuardianMailer, type: :mailer do
  describe "#waiver_reset" do
    let(:event) { create(:event) }
    let(:participant_event) { create(:participant_event, event: event) }
    let(:guardian_participant_event) do
      create(:guardian_participant_event, participant_event: participant_event)
    end

    # Expiry is measured from invite_token_sent_at alone, so a reset sent after
    # the original invite aged out has to restart the window — otherwise the
    # link in this very email 404s the moment the guardian clicks it.
    it "restarts the invite window so the emailed link still resolves" do
      guardian_participant_event.generate_invite_token!
      guardian_participant_event.update!(
        invite_token_sent_at: (GuardianParticipantEvent::INVITE_VALIDITY + 1.day).ago
      )

      described_class.waiver_reset(
        guardian_participant_event: guardian_participant_event,
        waiver_type: :waiver
      ).deliver_now

      guardian_participant_event.reload
      expect(guardian_participant_event.invite_expired?).to be(false)
      expect(
        GuardianParticipantEvent.find_by_invite_token!(guardian_participant_event.invite_token)
      ).to eq(guardian_participant_event)
    end
  end
end
