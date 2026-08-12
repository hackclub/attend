require "rails_helper"

RSpec.describe Exports::CsvBuilder do
  let(:event) { create(:event) }

  def build_csv(columns:, filters: [], row_mode: "participant")
    builder = described_class.new(event: event, columns: columns, filters: filters, row_mode: row_mode)
    [ CSV.parse(builder.to_csv), builder ]
  end

  def filter(field_key, operator, value = nil)
    Exports::Filter.new(field: Exports::FieldRegistry.fetch(field_key), operator: operator, value: value)
  end

  it "renders headers in column order and one row per participant" do
    pe = create(:participant_event, event: event, status: "complete")
    create(:participant_event, event: event, status: "invited")

    rows, builder = build_csv(columns: %w[participant.email participant_event.status])

    expect(rows.first).to eq([ "Email", "Status" ])
    expect(rows.size).to eq(3)
    expect(rows.map(&:last)).to include("complete", "invited")
    expect(rows).to include([ pe.participant.email, "complete" ])
    expect(builder.row_count).to eq(2)
  end

  it "formats booleans as Yes/No and dates as ISO" do
    pe = create(:participant_event, event: event)
    pe.create_medical!(has_anaphylaxis_risk: true)
    pe.create_accommodation!(check_in_date: Date.new(2026, 7, 10))

    rows, = build_csv(columns: %w[medical.has_anaphylaxis_risk accommodation.check_in_date])

    expect(rows.last).to eq([ "Yes", "2026-07-10" ])
  end

  describe "filters" do
    before do
      @complete = create(:participant_event, :checked_in, event: event, status: "complete")
      @invited = create(:participant_event, event: event, status: "invited")
      @complete.create_dietary!(diet_type: "vegan")
    end

    it "applies enum in filters" do
      rows, = build_csv(columns: %w[participant.email], filters: [ filter("participant_event.status", "in", [ "complete" ]) ])
      expect(rows.size).to eq(2)
      expect(rows.last).to eq([ @complete.participant.email ])
    end

    it "applies present filters" do
      rows, = build_csv(columns: %w[participant.email], filters: [ filter("participant_event.checked_in_at", "present") ])
      expect(rows.size).to eq(2)
      expect(rows.last).to eq([ @complete.participant.email ])
    end

    it "filters on fields that are not exported columns" do
      rows, = build_csv(columns: %w[participant.email], filters: [ filter("dietary.diet_type", "contains", "VEG") ])
      expect(rows.size).to eq(2)
      expect(rows.last).to eq([ @complete.participant.email ])
    end

    it "requires all filters to match" do
      rows, = build_csv(columns: %w[participant.email], filters: [
        filter("participant_event.status", "in", [ "complete" ]),
        filter("participant_event.checked_in_at", "blank")
      ])
      expect(rows.size).to eq(1)
    end

    it "applies date before/after filters with day semantics" do
      pe = create(:participant_event, event: event)
      pe.create_accommodation!(check_in_date: Date.new(2026, 7, 10))

      before_rows, = build_csv(columns: %w[participant.email], filters: [ filter("accommodation.check_in_date", "before", "2026-07-11") ])
      after_rows, = build_csv(columns: %w[participant.email], filters: [ filter("accommodation.check_in_date", "after", "2026-07-10") ])

      expect(before_rows.size).to eq(2)
      expect(after_rows.size).to eq(1)
    end

    # "Checked In At is present" has to see scan-based check-ins, which is all of
    # them.
    it "treats a check-in scan as a present check-in time" do
      context = event.scan_contexts.find_by!(checks_in: true)
      user = create(:user)
      scanned = create(:participant_event, event: event)
      scanned.scans.create!(scan_context: context, user: user, scanned_at: 2.hours.ago)
      scanned.scans.create!(scan_context: context, user: user, scanned_at: 1.hour.ago)

      rows, = build_csv(
        columns: %w[participant.email participant_event.checked_in_at participant_event.checked_in],
        filters: [ filter("participant_event.checked_in_at", "present") ]
      )

      # @complete is :checked_in, plus the participant scanned above.
      expect(rows.size).to eq(3)
      scanned_row = rows.find { |r| r.first == scanned.participant.email }
      # Earliest check-in scan wins, and the boolean column agrees.
      expect(scanned_row[1]).to eq(2.hours.ago.strftime("%Y-%m-%d %H:%M"))
      expect(scanned_row[2]).to eq("Yes")

      blank_rows, = build_csv(columns: %w[participant.email], filters: [ filter("participant_event.checked_in_at", "blank") ])
      expect(blank_rows.map(&:first)).to include(@invited.participant.email)
      expect(blank_rows.map(&:first)).not_to include(scanned.participant.email)
    end

    it "filters on the checked-in boolean" do
      context = event.scan_contexts.find_by!(checks_in: true)
      scanned = create(:participant_event, event: event)
      scanned.scans.create!(scan_context: context, user: create(:user), scanned_at: Time.current)

      yes_rows, = build_csv(columns: %w[participant.email], filters: [ filter("participant_event.checked_in", "true") ])
      no_rows, = build_csv(columns: %w[participant.email], filters: [ filter("participant_event.checked_in", "false") ])

      expect(yes_rows.map(&:first)).to include(scanned.participant.email, @complete.participant.email)
      expect(no_rows.map(&:first)).to eq([ "Email", @invited.participant.email ])
    end
  end

  describe "filter validity" do
    it "rejects operators that do not match the field type" do
      expect(filter("participant.email", "before", "2026-01-01").valid?).to be(false)
      expect(filter("participant.email", "contains", "a").valid?).to be(true)
    end

    it "rejects unparseable dates and unknown enum values" do
      expect(filter("participant_event.checked_in_at", "before", "not-a-date").valid?).to be(false)
      expect(filter("participant_event.status", "in", [ "bogus" ]).valid?).to be(false)
    end

    it "rejects filters on leg-level fields" do
      expect(filter("leg.flight_code", "contains", "UA").valid?).to be(false)
    end
  end

  describe "flight_leg row mode" do
    it "emits one row per plane leg, skipping non-plane travel and flightless participants" do
      flyer = create(:participant_event, event: event)
      inbound = Travel.create!(participant_event: flyer, direction: "inbound", mode: "plane")
      create(:travel_leg, travel: inbound, position: 0, flight_code: "UA100", departure_airport: "SFO", arrival_airport: "ORD")
      create(:travel_leg, travel: inbound, position: 1, flight_code: "UA200", departure_airport: "ORD", arrival_airport: "BOS")
      outbound = Travel.create!(participant_event: flyer, direction: "outbound", mode: "bus")
      create(:travel_leg, travel: outbound, position: 0, flight_code: "IGNORED", departure_airport: "JFK", arrival_airport: "LAX")
      create(:participant_event, event: event)

      rows, builder = build_csv(
        columns: %w[participant.full_legal_name leg.direction leg.flight_code],
        row_mode: "flight_leg"
      )

      expect(rows.size).to eq(3)
      expect(rows[1]).to eq([ flyer.participant.full_name, "inbound", "UA100" ])
      expect(rows[2]).to eq([ flyer.participant.full_name, "inbound", "UA200" ])
      expect(builder.row_count).to eq(2)
    end

    it "leaves leg-level columns blank in participant mode" do
      pe = create(:participant_event, event: event)
      travel = Travel.create!(participant_event: pe, direction: "inbound", mode: "plane")
      create(:travel_leg, travel: travel, position: 0, flight_code: "UA100", departure_airport: "SFO", arrival_airport: "BOS")

      rows, = build_csv(columns: %w[participant.email leg.flight_code])

      expect(rows.last).to eq([ pe.participant.email, nil ])
    end
  end

  it "orders emergency contact slots by priority" do
    pe = create(:participant_event, event: event)
    EmergencyContact.create!(participant_event: pe, name: "Second", phone: "+12025550002", priority: 2)
    EmergencyContact.create!(participant_event: pe, name: "First", phone: "+12025550001", priority: 1)

    rows, = build_csv(columns: %w[emergency_contact.1.name emergency_contact.2.name])

    expect(rows.last).to eq([ "First", "Second" ])
  end
end
