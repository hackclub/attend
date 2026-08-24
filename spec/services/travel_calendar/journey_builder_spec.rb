require "rails_helper"

RSpec.describe TravelCalendar::JourneyBuilder do
  subject(:entries) { described_class.new(event: event).call }

  let(:event) { create(:event, timezone: "Europe/London", groups_enabled: true) }

  def create_travel(mode:, direction:, participant: nil, **attributes)
    participant_event = create(
      :participant_event,
      event: event,
      participant: participant || create(:participant),
      status: :complete
    )
    travel = Travel.create!(
      participant_event: participant_event,
      mode: mode,
      direction: direction,
      **attributes
    )

    [ travel, participant_event ]
  end

  def create_plane_travel(arrival_time: nil, departure_time: nil, **attributes)
    travel, participant_event = create_travel(mode: "plane", **attributes)
    create(
      :travel_leg,
      travel: travel,
      departure_time: departure_time || arrival_time - 2.hours,
      arrival_time: arrival_time || departure_time + 2.hours,
      departure_airport: "JFK",
      arrival_airport: "LHR",
      flight_code: "BA178"
    )

    [ travel, participant_event ]
  end

  it "includes every travel mode in one chronological result" do
    create_travel(mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 9))
    create_travel(mode: "bus", direction: "outbound", departure_time: Time.utc(2026, 8, 24, 12))
    create_travel(mode: "car", direction: "inbound", expected_arrival_time: Time.utc(2026, 8, 25, 8))
    create_travel(mode: "other", direction: "outbound", other_details: "Collected by guardian")
    create_plane_travel(arrival_time: Time.utc(2026, 8, 24, 10), direction: "inbound")

    expect(entries.map { |entry| entry[:mode] }).to include("plane", "train", "bus", "car", "other")
    expect(entries.map { |entry| entry[:primary_time_at] }.compact).to eq(
      entries.map { |entry| entry[:primary_time_at] }.compact.sort
    )
    expect(entries.last[:agenda_date]).to be_nil
  end

  it "groups an instant by its date in the event timezone" do
    create_travel(mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 23, 30))

    expect(entries.first[:agenda_date]).to eq(Date.new(2026, 8, 25))
  end

  it "uses direction-aware times, routes, and references for every transport mode" do
    plane, = create_plane_travel(arrival_time: Time.utc(2026, 8, 24, 10), direction: "inbound")
    create(:travel_leg, travel: plane, position: 2, departure_time: Time.utc(2026, 8, 24, 11), arrival_time: Time.utc(2026, 8, 24, 12), departure_airport: "LHR", arrival_airport: "CDG", flight_code: "BA304")
    train, = create_travel(mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 13), train_departure_station: "Waterloo", train_arrival_station: "Portsmouth", carrier: "South Western Railway")
    bus, = create_travel(mode: "bus", direction: "outbound", departure_time: Time.utc(2026, 8, 24, 14), bus_departure_location: "Venue", bus_arrival_location: "Heathrow", carrier: "National Express")
    car, = create_travel(mode: "car", direction: "inbound", expected_arrival_time: Time.utc(2026, 8, 24, 15), origin_address: "10 Downing Street")
    other, = create_travel(mode: "other", direction: "outbound", departure_time: Time.utc(2026, 8, 24, 16), other_details: "Collected by guardian", notes: "Call before arrival")

    entries_by_id = entries.index_by { |entry| entry[:id] }

    expect(entries_by_id.fetch(plane.id)).to include(primary_time_at: Time.utc(2026, 8, 24, 12), route: "JFK → LHR → CDG", reference: "BA178 · BA304")
    expect(entries_by_id.fetch(train.id)).to include(route: "Waterloo → Portsmouth", reference: "South Western Railway")
    expect(entries_by_id.fetch(bus.id)).to include(route: "Venue → Heathrow", reference: "National Express")
    expect(entries_by_id.fetch(car.id)).to include(route: "10 Downing Street", reference: nil)
    expect(entries_by_id.fetch(other.id)).to include(route: "Collected by guardian", reference: nil, details: "Call before arrival")
  end

  it "keeps partial routes and plane journeys without legs visible" do
    partial, = create_travel(mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 10), train_arrival_station: "Portsmouth")
    plane, = create_travel(mode: "plane", direction: "outbound")

    entries_by_id = entries.index_by { |entry| entry[:id] }

    expect(entries_by_id.fetch(partial.id)).to include(route: "Portsmouth", primary_time_at: Time.utc(2026, 8, 24, 10))
    expect(entries_by_id.fetch(plane.id)).to include(route: nil, reference: nil, primary_time_at: nil, agenda_date: nil)
  end

  it "includes only complete registrations" do
    complete, = create_travel(mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 10))
    incomplete = create(:participant_event, event: event, status: :in_progress)
    hidden = Travel.create!(participant_event: incomplete, mode: "bus", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 11))

    expect(entries.map { |entry| entry[:id] }).to eq([ complete.id ])
    expect(entries.map { |entry| entry[:id] }).not_to include(hidden.id)
  end

  it "sorts same-time and unscheduled journeys by participant name" do
    zoe = create(:participant, legal_first_name: "Zoe", legal_last_name: "Zebra")
    amy = create(:participant, legal_first_name: "Amy", legal_last_name: "Aardvark")
    noah = create(:participant, legal_first_name: "Noah", legal_last_name: "Null")
    ada = create(:participant, legal_first_name: "Ada", legal_last_name: "Absent")
    create_travel(mode: "train", direction: "inbound", participant: zoe, arrival_time: Time.utc(2026, 8, 24, 10))
    create_travel(mode: "bus", direction: "inbound", participant: amy, arrival_time: Time.utc(2026, 8, 24, 10))
    create_travel(mode: "other", direction: "inbound", participant: noah)
    create_travel(mode: "car", direction: "outbound", participant: ada)

    expect(entries.map { |entry| entry[:participant_name] }).to eq([ "Amy Aardvark", "Zoe Zebra", "Ada Absent", "Noah Null" ])
  end

  it "includes participant and group presentation data" do
    participant = create(:participant, legal_first_name: "Avery", legal_last_name: "Example", preferred_name: "Ave")
    travel, participant_event = create_travel(mode: "train", direction: "inbound", participant: participant, arrival_time: Time.utc(2026, 8, 24, 10))
    group = create(:group, event: event, name: "Blue Team", color: "#123456")
    create(:group_membership, group: group, participant_event: participant_event)

    expect(entries.first).to include(
      id: travel.id,
      participant_id: participant.id,
      participant_event_id: participant_event.id,
      participant_name: "Avery Example",
      participant_preferred_name: "Ave",
      groups: [ { id: group.id, name: "Blue Team", color: "#123456" } ]
    )
  end

  it "resolves inbound pickup state from scans before manual dismissal" do
    unscanned, unscanned_registration = create_travel(mode: "train", direction: "inbound")
    dismissed, dismissed_registration = create_travel(mode: "train", direction: "inbound", pickup_dismissed_at: Time.current)
    checked_in, checked_in_registration = create_travel(mode: "train", direction: "inbound", pickup_dismissed_at: Time.current)
    collected, collected_registration = create_travel(mode: "train", direction: "inbound", pickup_dismissed_at: Time.current)
    outbound, outbound_registration = create_travel(mode: "train", direction: "outbound")
    check_in_context = event.scan_contexts.find_by!(checks_in: true)
    pickup_context = event.scan_contexts.create!(name: "Station pickup", checks_in: false, is_travel_pickup: true)

    checked_in_registration.scans.create!(scan_context: check_in_context, user: create(:user), scanned_at: Time.current)
    collected_registration.scans.create!(scan_context: check_in_context, user: create(:user), scanned_at: Time.current)
    collected_registration.scans.create!(scan_context: pickup_context, user: create(:user), scanned_at: Time.current)

    entries_by_registration = entries.index_by { |entry| entry[:participant_event_id] }

    expect(entries_by_registration.fetch(unscanned_registration.id)[:pickup_state]).to eq(:awaiting_pickup)
    expect(entries_by_registration.fetch(dismissed_registration.id)[:pickup_state]).to eq(:pickup_not_needed)
    expect(entries_by_registration.fetch(checked_in_registration.id)[:pickup_state]).to eq(:checked_in)
    expect(entries_by_registration.fetch(collected_registration.id)[:pickup_state]).to eq(:collected)
    expect(entries_by_registration.fetch(outbound_registration.id)[:pickup_state]).to be_nil
  end
end
