require "rails_helper"
require Rails.root.join("db/migrate/20261024120100_backfill_scan_context_kinds")

RSpec.describe BackfillScanContextKinds do
  let(:migration) { described_class.new.tap { |m| m.verbose = false } }
  let(:event) { create(:event) }

  it "gives each point a kind its flags agree with, writing nothing else" do
    venue = event.scan_contexts.first
    hotel = event.scan_contexts.create!(name: "Hotel")
    pickup = event.scan_contexts.create!(name: "Airport", is_travel_pickup: true)
    both = event.scan_contexts.create!(name: "Pickup and check-in", is_travel_pickup: true)
    both.update_columns(checks_in: true)
    lunch = event.scan_contexts.create!(name: "Lunch")
    event.update_columns(hotel_scan_context_id: hotel.id)
    create(:event).update_columns(hotel_scan_context_id: lunch.id) # another event's hotel isn't this one's lodging
    ScanContext.unscoped.update_all(kind: nil)
    flags = -> { ScanContext.unscoped.order(:created_at).pluck(:checks_in, :is_travel_pickup) }
    flags_before = flags.call

    migration.up

    expect([ venue, hotel, pickup, both, lunch ].map { |c| c.reload.kind }).to eq(%w[venue lodging pickup venue tracking_only])
    expect(flags.call).to eq(flags_before)

    hotel.update!(kind: "outing")
    migration.down
    expect(hotel.reload.kind).to eq("outing")
  end
end
