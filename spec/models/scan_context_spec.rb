require "rails_helper"

RSpec.describe ScanContext, type: :model do
  describe "travel pickup contexts" do
    it "supports travel pickup contexts" do
      context = create(:event).scan_contexts.create!(
        name: "Central Station",
        checks_in: false,
        is_travel_pickup: true
      )

      expect(context).to be_is_travel_pickup
    end
  end

  describe "schedule validation" do
    let(:event) { create(:event) }

    it "is valid with no schedule" do
      context = event.scan_contexts.new(name: "Check-in")
      expect(context).to be_valid
    end

    it "is valid with only a start or only an end" do
      expect(event.scan_contexts.new(name: "Check-in", starts_at: 1.hour.from_now)).to be_valid
      expect(event.scan_contexts.new(name: "Check-in", ends_at: 1.hour.from_now)).to be_valid
    end

    it "is valid when ends_at is after starts_at" do
      context = event.scan_contexts.new(name: "Dinner", starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
      expect(context).to be_valid
    end

    it "is invalid when ends_at is before or equal to starts_at" do
      context = event.scan_contexts.new(name: "Dinner", starts_at: 3.hours.from_now, ends_at: 1.hour.from_now)
      expect(context).not_to be_valid
      expect(context.errors[:ends_at]).to include("must be after the start time")

      context.ends_at = context.starts_at
      expect(context).not_to be_valid
    end
  end
end
