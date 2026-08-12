require "rails_helper"

RSpec.describe Airtable::SyncService do
  # Check-in is a Scan in a checks_in context, so the sync reads it from scans.
  let(:event) do
    create(:event, config: { "airtable_api_key" => "key-test", "airtable_base_id" => "app-test" })
  end
  let(:user) { create(:user) }
  let(:check_in) { event.scan_contexts.find_by!(checks_in: true) }
  let(:dinner) { event.scan_contexts.create!(name: "Dinner", checks_in: false) }

  def synced_check_in_cells(participant_events)
    rows = CSV.parse(described_class.new(event).serialize_all_to_csv(participant_events))
    header = rows.first
    checked_in = header.index("Checked In")
    checked_in_at = header.index("Checked In At")
    rows.drop(1).map { |row| [ row[checked_in], row[checked_in_at] ] }
  end

  it "reports the earliest check-in scan, ignoring non-check-in contexts" do
    pe = create(:participant_event, event: event)
    pe.scans.create!(scan_context: dinner, user: user, scanned_at: 5.hours.ago)
    pe.scans.create!(scan_context: check_in, user: user, scanned_at: 1.hour.ago)
    earliest = pe.scans.create!(scan_context: check_in, user: user, scanned_at: 3.hours.ago)

    expect(synced_check_in_cells([ pe ])).to eq([ [ "true", earliest.scanned_at.iso8601 ] ])
  end

  it "reports a participant with no check-in scan as not checked in" do
    pe = create(:participant_event, event: event)
    pe.scans.create!(scan_context: dinner, user: user, scanned_at: 1.hour.ago)

    expect(synced_check_in_cells([ pe ])).to eq([ [ "false", nil ] ])
  end

  it "keeps the boolean and the timestamp in agreement" do
    scanned = create(:participant_event, event: event)
    scanned.scans.create!(scan_context: check_in, user: user, scanned_at: 1.hour.ago)
    not_scanned = create(:participant_event, event: event)

    cells = synced_check_in_cells([ scanned, not_scanned ])

    expect(cells.map(&:first)).to eq([ "true", "false" ])
    expect(cells.map { |(_, at)| at.present? }).to eq([ true, false ])
  end

  it "loads scan contexts up front so a full sync does not query per scan" do
    3.times do
      pe = create(:participant_event, event: event)
      pe.scans.create!(scan_context: check_in, user: user, scanned_at: 1.hour.ago)
    end

    loaded = described_class.new(event).send(:load_participant_events)

    queries = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries += 1 unless payload[:name].to_s.in?([ "SCHEMA", "TRANSACTION" ])
    end
    begin
      described_class.new(event).serialize_all_to_csv(loaded)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    expect(queries).to eq(0)
  end
end
