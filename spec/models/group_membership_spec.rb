require "rails_helper"

RSpec.describe GroupMembership, type: :model do
  let(:event) { create(:event) }
  let(:other_event) { create(:event) }
  let(:group) { create(:group, event: event) }
  let(:pe) { create(:participant_event, event: event) }

  it "is valid when the group and participant_event share an event" do
    expect(build(:group_membership, group: group, participant_event: pe)).to be_valid
  end

  it "is invalid when the group and participant_event belong to different events" do
    other_pe = create(:participant_event, event: other_event)
    membership = build(:group_membership, group: group, participant_event: other_pe)
    expect(membership).not_to be_valid
    expect(membership.errors[:base].first).to match(/same event/)
  end

  it "enforces uniqueness per (group, participant_event)" do
    create(:group_membership, group: group, participant_event: pe)
    dup = build(:group_membership, group: group, participant_event: pe)
    expect(dup).not_to be_valid
  end
end
