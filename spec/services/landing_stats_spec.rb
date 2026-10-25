require "rails_helper"

RSpec.describe LandingStats do
  let(:now) { Time.zone.parse("2026-10-24 12:00:00") }

  def register(event, country:, status: :complete)
    participant = create(:participant, country_of_residence: country)
    create(:participant_event, participant: participant, event: event, status: status)
    participant
  end

  it "counts started events with standing registrations, distinct students, and folded countries" do
    happened = create(:event, name: "Mock Winter", starts_at: now - 30.days, ends_at: now - 27.days,
                      location_latitude: 48.2345, location_longitude: 16.4123)
    second = create(:event, name: "Mock Spring", starts_at: now - 10.days, ends_at: now - 8.days,
                     location_latitude: 1.3, location_longitude: 103.8)
    empty = create(:event, name: "Mock Nobody Came", starts_at: now - 5.days, ends_at: now - 4.days)
    create(:event, name: "Mock Someday", starts_at: now + 20.days, ends_at: now + 22.days,
           location_latitude: 51.5, location_longitude: -0.1)
    create(:event, :draft, name: "Mock Unannounced", starts_at: now + 40.days, ends_at: now + 41.days,
           location_latitude: 40.7, location_longitude: -74.0)
    unlisted = create(:event, :draft, name: "Mock Unlisted", starts_at: now - 3.days, ends_at: now - 2.days,
                      location_latitude: 35.6, location_longitude: 139.7)

    returning = register(happened, country: "United States")
    create(:participant_event, participant: returning, event: second, status: :complete)
    register(happened, country: "US")
    register(happened, country: "USA")
    register(second, country: "IN")
    register(second, country: "India")
    register(second, country: "Narnia")
    register(second, country: "Morocco", status: :withdrawn)
    register(second, country: "Peru", status: :rejected)
    register(empty, country: "Ireland", status: :withdrawn)
    register(unlisted, country: "Japan")

    stats = described_class.new(now: now).to_h

    # The Narnia student counts; the made-up residence is just never published.
    expect(stats.slice(:events, :students, :countries)).to eq(events: 3, students: 7, countries: 3)

    # The unlisted event counts toward the headline but never reaches the map.
    expect(stats[:pins].map { |p| [ p[:name], p[:state], p[:students] ] }).to eq([
      [ "Mock Winter", "past", 3 ],
      [ "Mock Spring", "past", 4 ],
      [ "Mock Someday", "upcoming", 0 ]
    ])
    expect(stats[:pins].first.keys).to contain_exactly(:name, :location, :dates, :lat, :lon, :students, :state)
    expect(stats[:pins].first.slice(:lat, :lon)).to eq(lat: 48.23, lon: 16.41)

    # Countries below the pin threshold keep their row but not their events.
    expect(stats[:roll]).to eq([
      { name: "United States", students: 3, pins: [ 0, 1 ] },
      { name: "India", students: 2, pins: [] },
      { name: "Japan", students: 1, pins: [] }
    ])
  end

  it "marks an event that is running right now as live" do
    live = create(:event, starts_at: now - 1.day, ends_at: now + 1.day,
                  location_latitude: 10, location_longitude: 10)
    register(live, country: "Canada")

    stats = described_class.new(now: now).to_h

    expect(stats[:pins].sole[:state]).to eq("live")
  end

  it "caches the computed hash for an hour" do
    allow(Rails.cache).to receive(:fetch).with(described_class::CACHE_KEY, expires_in: 1.hour).and_return({ events: 1 })

    expect(described_class.fetch).to eq({ events: 1 })
  end

  describe ".normalize_country" do
    it "folds codes and spellings into one name and leaves the rest as typed" do
      expect(described_class.normalize_country(" GB ")).to eq("United Kingdom")
      expect(described_class.normalize_country("United State")).to eq("United States")
      expect(described_class.normalize_country("HK")).to eq("Hong Kong")
      expect(described_class.normalize_country("日本")).to eq("Japan")
      expect(described_class.normalize_country("Nicaragua")).to eq("Nicaragua")
    end
  end
end
