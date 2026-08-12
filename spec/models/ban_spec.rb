require 'rails_helper'

RSpec.describe Ban, type: :model do
  describe ".banned?" do
    it "is true for an active ban (case-insensitive)" do
      create(:ban, email: "banned@example.com")
      expect(Ban.banned?("BANNED@example.com")).to be true
      expect(Ban.banned?(" banned@example.com ")).to be true
    end

    it "matches alias emails on the same ban" do
      ban = build(:ban, email: "primary@example.com")
      ban.ban_emails.build(email: "alias@example.com")
      ban.save!

      expect(Ban.banned?("alias@example.com")).to be true
    end

    it "is false for unrelated emails" do
      create(:ban, email: "banned@example.com")
      expect(Ban.banned?("someone@example.com")).to be false
    end

    it "is false for an expired ban" do
      create(:ban, :expired, email: "banned@example.com")
      expect(Ban.banned?("banned@example.com")).to be false
    end

    it "is true for an indefinite (nil expiry) ban" do
      create(:ban, email: "banned@example.com", expires_at: nil)
      expect(Ban.banned?("banned@example.com")).to be true
    end

    it "is false for a revoked ban" do
      ban = create(:ban, email: "banned@example.com")
      ban.revoke!
      expect(Ban.banned?("banned@example.com")).to be false
    end

    it "is false for blank input" do
      expect(Ban.banned?(nil)).to be false
      expect(Ban.banned?("")).to be false
    end
  end

  describe "validations" do
    it "requires at least one email" do
      expect(Ban.new(reason: "x")).not_to be_valid
    end

    it "rejects duplicate emails across bans (case-insensitive)" do
      create(:ban, email: "dupe@example.com")
      dupe = build(:ban, email: "DUPE@example.com")
      expect(dupe).not_to be_valid
    end
  end

  describe "revocation" do
    it "marks the ban revoked and reports 'Revoked' status, then reinstates" do
      ban = create(:ban, email: "banned@example.com")
      expect(ban.status).to eq("Indefinite")

      ban.revoke!
      expect(ban).to be_revoked
      expect(ban).not_to be_active
      expect(ban.status).to eq("Revoked")

      ban.reinstate!
      expect(ban).not_to be_revoked
      expect(ban.status).to eq("Indefinite")
    end
  end

  describe "#affected_participants" do
    it "returns enrolled participants matching the banned emails" do
      participant = create(:participant, email: "banned@example.com")
      ban = create(:ban, email: "banned@example.com")
      expect(ban.affected_participants).to include(participant)
    end
  end
end
