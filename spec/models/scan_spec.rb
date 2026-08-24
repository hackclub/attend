require "rails_helper"

RSpec.describe Scan, type: :model do
  describe "travel pickup scopes" do
    it "filters travel pickup and check-in scan contexts" do
      event = create(:event)
      participant_event = create(:participant_event, event: event)
      user = create(:user)
      travel_pickup_context = event.scan_contexts.create!(
        name: "Central Station",
        checks_in: false,
        is_travel_pickup: true
      )
      check_in_context = event.scan_contexts.find_by!(checks_in: true)
      other_context = event.scan_contexts.create!(
        name: "Workshop",
        checks_in: false,
        is_travel_pickup: false
      )

      travel_pickup_scan = participant_event.scans.create!(
        scan_context: travel_pickup_context,
        user: user,
        scanned_at: Time.current
      )
      check_in_scan = participant_event.scans.create!(
        scan_context: check_in_context,
        user: user,
        scanned_at: Time.current
      )
      participant_event.scans.create!(
        scan_context: other_context,
        user: user,
        scanned_at: Time.current
      )

      expect(Scan.for_airport).to contain_exactly(travel_pickup_scan)
      expect(Scan.for_airport_or_check_in).to contain_exactly(travel_pickup_scan, check_in_scan)
    end
  end
end
