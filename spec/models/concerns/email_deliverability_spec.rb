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

  describe "address shape" do
    it "rejects an address whose domain has no top-level part, which Postmark refuses" do
      participant = build(:participant, email: "someone@nowhere")
      guardian = build(:guardian, email: "someone@nowhere")

      expect(participant).not_to be_valid
      expect(participant.errors.details[:email]).to eq([ { error: :invalid } ])
      expect(guardian).not_to be_valid
    end

    it "accepts ordinary, subdomain and internationalised domains" do
      %w[someone@example.com someone@mail.example.co.uk someone@example.xn--p1ai].each do |address|
        expect(build(:participant, email: address)).to be_valid, address
      end
    end

    it "leaves an existing row with a bad address editable until the address itself changes" do
      participant = create(:participant)
      participant.update_column(:email, "someone@nowhere")

      expect(participant.reload.update(preferred_name: "Sky")).to be(true)
      expect(participant.update(email: "someone@elsewhere")).to be(false)
    end
  end
end
