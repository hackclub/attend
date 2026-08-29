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
      # Minting a token is not the same as sending it, and an invite with no
      # send recorded is treated as revoked -- stamp it the way the mailers do
      # so this exercises the race rather than expiry.
      gpe.update!(invite_token_sent_at: Time.current)

      expect(stale.generate_invite_token!).to eq(token)
      expect(described_class.find_by_invite_token!(token)).to eq(gpe)
    end
  end

  describe "#invite_expired?" do
    let(:gpe) { create(:guardian_participant_event) }

    it "is false inside the window from the send" do
      gpe.update!(invite_token_sent_at: 2.days.ago)

      expect(gpe.invite_expired?).to be(false)
    end

    it "is true once the send falls outside the window and nothing else happened" do
      gpe.update!(invite_token_sent_at: (described_class::INVITE_VALIDITY + 1.day).ago)

      expect(gpe.invite_expired?).to be(true)
    end

    # The whole point of the sliding window: someone gathering documents for a
    # fortnight must not lose the link they are actively using.
    it "is false when the guardian used the link recently, however old the send" do
      gpe.update!(
        invite_token_sent_at: 30.days.ago,
        invite_last_used_at: 1.day.ago
      )

      expect(gpe.invite_expired?).to be(false)
    end

    it "is true once the last use also falls outside the window" do
      gpe.update!(
        invite_token_sent_at: 30.days.ago,
        invite_last_used_at: (described_class::INVITE_VALIDITY + 1.day).ago
      )

      expect(gpe.invite_expired?).to be(true)
    end

    # Admins null the send stamp to revoke a link (e.g. after correcting a
    # guardian's email). That used to read as "never expires".
    it "is true when the invite has no send recorded at all" do
      gpe.update!(invite_token_sent_at: nil, invite_last_used_at: nil)

      expect(gpe.invite_expired?).to be(true)
    end

    it "does not resolve a revoked token" do
      token = gpe.generate_invite_token!
      gpe.update!(invite_token_sent_at: nil, invite_last_used_at: nil)

      expect { described_class.find_by_invite_token!(token) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "#touch_invite_use!" do
    it "extends the window" do
      gpe = create(:guardian_participant_event, invite_token_sent_at: 6.days.ago)

      gpe.touch_invite_use!

      expect(gpe.reload.invite_last_used_at).to be_within(5.seconds).of(Time.current)
    end

    it "does not write again within the throttle interval" do
      recent = 5.minutes.ago
      gpe = create(:guardian_participant_event, invite_token_sent_at: 1.day.ago, invite_last_used_at: recent)

      expect { gpe.touch_invite_use! }
        .not_to change { gpe.reload.invite_last_used_at }
    end
  end

  describe "#invite_url" do
    # An unstamped invite is dead, so producing a shareable link has to count
    # as a send or admins would hand out URLs that 404.
    it "stamps the send so the link it returns actually resolves" do
      gpe = create(:guardian_participant_event, invite_token_sent_at: nil)

      url = gpe.invite_url

      expect(gpe.reload.invite_expired?).to be(false)
      token = url[%r{/guardian/portal/([A-Za-z0-9_\-]+)}, 1]
      expect(described_class.find_by_invite_token!(token)).to eq(gpe)
    end
  end

  describe "guardian email vs participant email" do
    it "refuses to link a guardian who shares the participant's email" do
      participant_event = create(:participant_event)
      guardian = create(:guardian, email: participant_event.participant.email.upcase)

      gpe = described_class.new(guardian: guardian, participant_event: participant_event)

      expect(gpe).not_to be_valid
      expect(gpe.errors[:base])
        .to include("Guardian email cannot be the same as the participant's email address")
    end

    it "still allows updates to a link that already collides" do
      gpe = create(:guardian_participant_event)
      gpe.guardian.update_column(:email, gpe.participant_event.participant.email)

      expect(gpe.reload.update(status: :in_progress)).to be(true)
    end
  end
end
