require "rails_helper"

RSpec.describe Passport, type: :model do
  describe "generated identifiers" do
    it "generates a private UUID and a public serial number" do
      passport = create(:passport)

      expect(passport.token).to match(/\A[0-9a-f-]{36}\z/)
      expect(passport.serial_number).to match(/\AHCP-[A-F0-9]{8}\z/)
    end

    it "generates unique identifiers" do
      passports = create_list(:passport, 2)

      expect(passports.map(&:token).uniq.size).to eq(2)
      expect(passports.map(&:serial_number).uniq.size).to eq(2)
    end
  end

  describe ".ensure_pending_for!" do
    it "reuses the newest pending passport" do
      user = create(:user)
      older = create(:passport, user: user, created_at: 1.day.ago)
      newer = create(:passport, user: user)

      expect(described_class.ensure_pending_for!(user)).to eq(newer)
      expect(user.passports.count).to eq(2)
      expect(older).to be_pending
    end

    it "creates a pending passport when none exists" do
      user = create(:user)

      expect { described_class.ensure_pending_for!(user) }
        .to change(user.passports, :count).by(1)
      expect(user.passports.sole).to be_pending
    end
  end

  describe "lifecycle" do
    it "starts pending and confirms only with the exact private token" do
      staff = create(:user)
      passport = create(:passport)

      expect(passport).to be_pending
      expect {
        passport.confirm!(presented_token: SecureRandom.uuid, actor: staff)
      }.to raise_error(Passport::TokenMismatch)

      passport.confirm!(presented_token: passport.token, actor: staff)

      expect(passport.reload).to be_active
      expect(passport.paired_by).to eq(staff)
      expect(passport.paired_at).to be_present
    end

    it "does not confirm a passport outside the pending state" do
      passport = create(:passport, :active)

      expect {
        passport.confirm!(presented_token: passport.token, actor: create(:user))
      }.to raise_error(Passport::InvalidState)
    end

    it "revokes an active passport and records the actor" do
      passport = create(:passport, :active)
      staff = create(:user)

      passport.revoke!(actor: staff)

      expect(passport.reload).to be_revoked
      expect(passport).not_to be_active
      expect(passport.revoked_by).to eq(staff)
      expect(passport.revoked_at).to be_present
    end

    it "does not revoke a pending passport" do
      passport = create(:passport)

      expect {
        passport.revoke!(actor: create(:user))
      }.to raise_error(Passport::InvalidState)
    end

    it "allows multiple active passports and revokes only the selected one" do
      user = create(:user)
      first = create(:passport, :active, user: user)
      second = create(:passport, :active, user: user)

      first.revoke!(actor: create(:user))

      expect(first.reload).to be_revoked
      expect(second.reload).to be_active
    end
  end
end
