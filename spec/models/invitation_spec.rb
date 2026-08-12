require 'rails_helper'

RSpec.describe Invitation, type: :model do
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
