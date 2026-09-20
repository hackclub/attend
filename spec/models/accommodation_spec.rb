require "rails_helper"

RSpec.describe Accommodation, type: :model do
  let(:participant_event) { create(:participant_event) }

  it "does not treat a blank persisted record as submitted preferences" do
    accommodation = Accommodation.create!(participant_event: participant_event)

    expect(accommodation.preferences_submitted?).to be(false)
  end

  it "treats a selected gender as submitted preferences" do
    accommodation = Accommodation.create!(participant_event: participant_event, gender_identity: "female")

    expect(accommodation.preferences_submitted?).to be(true)
  end
end
