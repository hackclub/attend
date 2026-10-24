require "rails_helper"

RSpec.describe ScanContext, type: :model do
  describe "kinds" do
    let(:event) { create(:event) }

    it "writes the old flags from the kind, so older readers and the API keep working" do
      pickup = event.scan_contexts.create!(name: "Airport", kind: "pickup")
      expect(pickup).to have_attributes(checks_in: false, is_travel_pickup: true)

      pickup.update!(kind: "venue")
      expect(pickup).to have_attributes(checks_in: true, is_travel_pickup: false)
    end

    it "reads a kind from the old flags for points saved without one" do
      expect(event.scan_contexts.first.kind).to eq("venue")
      expect(event.scan_contexts.create!(name: "Station", is_travel_pickup: true).kind).to eq("pickup")
      expect(event.scan_contexts.create!(name: "Lunch").kind).to eq("tracking_only")
    end

    it "leaves the old flags alone when a save doesn't change the kind" do
      both = event.scan_contexts.create!(name: "Both", kind: "pickup")
      both.update_columns(checks_in: true)

      both.update!(name: "Renamed")
      expect(both.reload).to have_attributes(checks_in: true, is_travel_pickup: true)
    end

    it "counts a point saved without a kind by its flags" do
      venue = event.scan_contexts.first
      venue.update_columns(kind: nil)
      scan = create(:participant_event, event: event).scans.create!(scan_context: venue, user: create(:user), scanned_at: Time.current)

      expect(venue.reload.kind_label).to eq("Venue")
      expect(Scan.placing).to include(scan)
    end

    it "keeps the event's last venue point a venue" do
      venue = event.scan_contexts.first
      venue.kind = "outing"

      expect(venue).not_to be_valid
      expect(venue.errors[:base].first).to include("at least one Venue")
    end
  end

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
