require "rails_helper"

RSpec.describe Group, type: :model do
  describe "validations" do
    let(:event) { create(:event) }

    it "requires a name unique per event" do
      create(:group, event: event, name: "Hardware")
      dup = build(:group, event: event, name: "Hardware")
      expect(dup).not_to be_valid
      expect(dup.errors[:name]).to be_present
    end

    it "auto-generates a slug from the name" do
      g = create(:group, event: event, name: "General Attendance!")
      expect(g.slug).to eq("general-attendance")
    end

    it "rejects malformed colors" do
      g = build(:group, event: event, color: "red")
      expect(g).not_to be_valid
    end

    it "accepts 6-digit hex colors with or without #" do
      expect(build(:group, event: event, color: "ec3750")).to be_valid
      expect(build(:group, event: event, color: "#33D6A6")).to be_valid
    end
  end

  describe "#normalized_color" do
    it "prefixes with # when missing" do
      expect(build(:group, color: "ec3750").normalized_color).to eq("#ec3750")
    end

    it "returns nil when blank" do
      expect(build(:group, color: nil).normalized_color).to be_nil
    end
  end

  describe "associations" do
    it "destroys memberships on group destroy" do
      g = create(:group)
      pe = create(:participant_event, event: g.event)
      create(:group_membership, group: g, participant_event: pe)
      expect { g.destroy }.to change(GroupMembership, :count).by(-1)
    end
  end
end
