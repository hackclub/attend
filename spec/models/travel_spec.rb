require "rails_helper"

RSpec.describe Travel, type: :model do
  describe "#dismiss_pickup!" do
    it "rejects outbound travel without changing pickup state" do
      travel = Travel.create!(
        participant_event: create(:participant_event),
        direction: "outbound",
        mode: "bus"
      )

      expect { travel.dismiss_pickup! }.to raise_error(ActiveRecord::RecordInvalid, /inbound travel/)
      expect(travel.reload.pickup_dismissed_at).to be_nil
      expect(travel).not_to be_pickup_dismissed
    end
  end
end
