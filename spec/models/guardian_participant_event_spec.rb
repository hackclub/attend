require "rails_helper"

RSpec.describe GuardianParticipantEvent do
  describe "#generate_invite_token!" do
    it "generates a token and stores its digest" do
      gpe = create(:guardian_participant_event)

      token = gpe.generate_invite_token!

      expect(token).to be_present
      expect(gpe.reload.invite_token_digest).to eq(Digest::SHA256.hexdigest(token))
    end

    it "returns the existing token on subsequent calls" do
      gpe = create(:guardian_participant_event)

      token = gpe.generate_invite_token!

      expect(gpe.generate_invite_token!).to eq(token)
    end

    it "does not overwrite a token generated after this instance was loaded" do
      gpe = create(:guardian_participant_event)
      # Simulates the invitation mailer and SMS jobs racing: both load the
      # record while the token is blank, then generate one after the other.
      stale = described_class.find(gpe.id)

      token = gpe.generate_invite_token!

      expect(stale.generate_invite_token!).to eq(token)
      expect(described_class.find_by_invite_token!(token)).to eq(gpe)
    end
  end
end
