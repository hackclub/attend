require "rails_helper"

RSpec.describe TravelCalendar::JourneyCache do
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:event) { create(:event, timezone: "UTC", groups_enabled: true) }
  let(:participant) { create(:participant, legal_first_name: "Alex", legal_last_name: "Original") }
  let(:participant_event) { create(:participant_event, event: event, participant: participant, status: :complete) }

  before do
    allow(Rails).to receive(:cache).and_return(memory_store)
  end

  def create_travel(participant_event: self.participant_event, mode: "train", direction: "inbound", **attributes)
    Travel.create!(
      participant_event: participant_event,
      mode: mode,
      direction: direction,
      **attributes
    )
  end

  def cached_entry(event: self.event, travel:)
    described_class.fetch(event).find { |entry| entry[:id] == travel.id }
  end

  it "refreshes after travel changes and destruction" do
    expect(described_class.fetch(event)).to be_empty

    travel = create_travel(arrival_time: Time.utc(2026, 8, 24, 10), train_arrival_station: "Old station")
    expect(cached_entry(travel: travel)).to include(primary_time_at: Time.utc(2026, 8, 24, 10), route: "Old station")

    travel.update!(arrival_time: Time.utc(2026, 8, 24, 12), train_arrival_station: "New station")
    expect(cached_entry(travel: travel)).to include(primary_time_at: Time.utc(2026, 8, 24, 12), route: "New station")

    travel.destroy!
    expect(described_class.fetch(event)).to be_empty
  end

  it "refreshes after flight-leg changes and destruction" do
    travel = create_travel(mode: "plane")
    expect(cached_entry(travel: travel)).to include(primary_time_at: nil, route: nil)

    leg = create(
      :travel_leg,
      travel: travel,
      departure_airport: "JFK",
      arrival_airport: "LHR",
      departure_time: Time.utc(2026, 8, 24, 8),
      arrival_time: Time.utc(2026, 8, 24, 10),
      flight_code: "BA178"
    )
    expect(cached_entry(travel: travel)).to include(primary_time_at: Time.utc(2026, 8, 24, 10), route: "JFK → LHR")

    leg.update!(arrival_airport: "CDG", arrival_time: Time.utc(2026, 8, 24, 11))
    expect(cached_entry(travel: travel)).to include(primary_time_at: Time.utc(2026, 8, 24, 11), route: "JFK → CDG")

    leg.destroy!
    expect(cached_entry(travel: travel)).to include(primary_time_at: nil, route: nil)
  end

  it "refreshes when registration status changes and after registration destruction" do
    registration = create(:participant_event, event: event, status: :in_progress)
    travel = create_travel(participant_event: registration, arrival_time: Time.utc(2026, 8, 24, 10))
    expect(described_class.fetch(event)).to be_empty

    registration.update!(status: :complete)
    expect(cached_entry(travel: travel)).to be_present

    travel.update!(is_unaccompanied_minor: true)
    expect(cached_entry(travel: travel)[:is_unaccompanied_minor]).to be(false)

    registration.update!(um_status: :approved)
    expect(cached_entry(travel: travel)[:is_unaccompanied_minor]).to be(true)

    registration.update!(status: :withdrawn)
    expect(described_class.fetch(event)).to be_empty

    registration.update!(status: :complete)
    expect(cached_entry(travel: travel)).to be_present

    registration.destroy!
    expect(described_class.fetch(event)).to be_empty
  end

  it "refreshes participant names in every event with a bounded event-id query" do
    events = 3.times.map { |index| create(:event, name: "Cache event #{index}") }
    travels = events.map do |registered_event|
      registration = create(:participant_event, event: registered_event, participant: participant, status: :complete)
      create_travel(participant_event: registration, arrival_time: Time.utc(2026, 8, 24, 10))
    end
    events.zip(travels).each do |registered_event, travel|
      expect(cached_entry(event: registered_event, travel: travel)[:participant_name]).to eq("Alex Original")
    end

    participant_event_selects = []
    subscriber = lambda do |*, payload|
      sql = payload[:sql]
      participant_event_selects << sql if sql.match?(/\ASELECT.+FROM "participant_events"/m)
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      participant.update!(legal_last_name: "Renamed")
    end

    expect(participant_event_selects.size).to be <= 2
    events.zip(travels).each do |registered_event, travel|
      expect(cached_entry(event: registered_event, travel: travel)[:participant_name]).to eq("Alex Renamed")
    end
  end

  it "refreshes after group and membership creation, changes, and destruction" do
    travel = create_travel(arrival_time: Time.utc(2026, 8, 24, 10))
    group = create(:group, event: event, name: "Old group", color: "#123456")
    expect(cached_entry(travel: travel)[:groups]).to be_empty

    membership = create(:group_membership, group: group, participant_event: participant_event)
    expect(cached_entry(travel: travel)[:groups]).to eq([ { id: group.id, name: "Old group", color: "#123456" } ])

    group.update!(name: "New group", color: "#654321")
    expect(cached_entry(travel: travel)[:groups]).to eq([ { id: group.id, name: "New group", color: "#654321" } ])

    membership.destroy!
    expect(cached_entry(travel: travel)[:groups]).to be_empty

    create(:group_membership, group: group, participant_event: participant_event)
    expect(cached_entry(travel: travel)[:groups]).not_to be_empty

    group.destroy!
    expect(cached_entry(travel: travel)[:groups]).to be_empty
  end

  it "refreshes groups when the event group flag changes" do
    travel = create_travel(arrival_time: Time.utc(2026, 8, 24, 10))
    group = create(:group, event: event, name: "Flagged group")
    create(:group_membership, group: group, participant_event: participant_event)
    event.update!(groups_enabled: false)
    expect(cached_entry(travel: travel)[:groups]).to be_empty

    event.update!(groups_enabled: true)
    expect(cached_entry(travel: travel)[:groups]).to eq([ { id: group.id, name: "Flagged group", color: "#ec3750" } ])
  end

  it "refreshes pickup state after scan creation, reassignment, and destruction" do
    travel = create_travel(arrival_time: Time.utc(2026, 8, 24, 10))
    pickup = event.scan_contexts.create!(name: "Pickup", checks_in: false, is_travel_pickup: true)
    check_in = event.scan_contexts.find_by!(checks_in: true)
    expect(cached_entry(travel: travel)[:pickup_state]).to eq(:awaiting_pickup)

    scan = participant_event.scans.create!(scan_context: pickup, user: create(:user), scanned_at: Time.current)
    expect(cached_entry(travel: travel)[:pickup_state]).to eq(:collected)

    scan.update!(scan_context: check_in)
    expect(cached_entry(travel: travel)[:pickup_state]).to eq(:checked_in)

    scan.destroy!
    expect(cached_entry(travel: travel)[:pickup_state]).to eq(:awaiting_pickup)
  end

  it "refreshes pickup state after scan-context flag changes and destruction" do
    travel = create_travel(arrival_time: Time.utc(2026, 8, 24, 10))
    context = event.scan_contexts.create!(name: "Pickup", checks_in: false, is_travel_pickup: true)
    participant_event.scans.create!(scan_context: context, user: create(:user), scanned_at: Time.current)
    expect(cached_entry(travel: travel)[:pickup_state]).to eq(:collected)

    context.update!(is_travel_pickup: false, checks_in: true)
    expect(cached_entry(travel: travel)[:pickup_state]).to eq(:checked_in)

    context.update!(checks_in: false)
    expect(cached_entry(travel: travel)[:pickup_state]).to eq(:awaiting_pickup)

    context.update!(is_travel_pickup: true)
    expect(cached_entry(travel: travel)[:pickup_state]).to eq(:collected)

    context.destroy!
    expect(cached_entry(travel: travel)[:pickup_state]).to eq(:awaiting_pickup)
  end

  it "regroups entries after the event timezone changes" do
    travel = create_travel(arrival_time: Time.utc(2026, 8, 24, 0, 30))
    expect(cached_entry(travel: travel)[:agenda_date]).to eq(Date.new(2026, 8, 24))

    event.update!(timezone: "America/Los_Angeles")
    expect(cached_entry(travel: travel)[:agenda_date]).to eq(Date.new(2026, 8, 23))
  end
end
