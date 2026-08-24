require "rails_helper"

RSpec.describe EmailDeliverability do
  describe ".mark_email_undeliverable!" do
    it "flags matching records case-insensitively" do
      participant = create(:participant, email: "Bounced@Example.com")

      Participant.mark_email_undeliverable!([ "bounced@example.com" ])

      expect(participant.reload.email_undeliverable_at).to be_present
    end

    it "does not touch records with other addresses" do
      participant = create(:participant, email: "fine@example.com")

      Participant.mark_email_undeliverable!([ "bounced@example.com" ])

      expect(participant.reload.email_undeliverable_at).to be_nil
    end

    it "does not move the timestamp of already-flagged records" do
      participant = create(:participant, email: "bounced@example.com", email_undeliverable_at: 2.days.ago)

      expect {
        Participant.mark_email_undeliverable!([ "bounced@example.com" ])
      }.not_to change { participant.reload.email_undeliverable_at }
    end

    it "ignores blank input" do
      expect(Participant.mark_email_undeliverable!([ nil, "" ])).to eq(0)
    end

    it "flags guardians too" do
      guardian = create(:guardian, email: "bounced@example.com")

      Guardian.mark_email_undeliverable!([ "bounced@example.com" ])

      expect(guardian.reload.email_undeliverable_at).to be_present
    end
  end

  describe "clearing the flag on email change" do
    it "clears the flag when the email is corrected" do
      participant = create(:participant, email: "typo@example.con", email_undeliverable_at: Time.current)

      participant.update!(email: "typo@example.com")

      expect(participant.reload.email_undeliverable_at).to be_nil
    end

    it "keeps the flag when other attributes change" do
      participant = create(:participant, email: "typo@example.con", email_undeliverable_at: Time.current)

      participant.update!(preferred_name: "Sam")

      expect(participant.reload.email_undeliverable_at).to be_present
    end

    it "allows setting the flag and email together explicitly" do
      participant = create(:participant, email: "old@example.com")

      participant.update!(email: "new@example.com", email_undeliverable_at: Time.current)

      expect(participant.reload.email_undeliverable_at).to be_present
    end
  end
end
