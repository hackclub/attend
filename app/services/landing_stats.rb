# Live numbers and map pins for the signed-out front door.
#
# The page states how many hackathons Attend has run, how many students it has
# supported and from how many countries, and plots every event on a map. All of
# it comes from the database so it can never go stale, and all of it is held in
# the cache for an hour so the busiest unauthenticated route never runs a count
# per request.
#
# What counts, and why:
# - An event counts once it has started and at least one registration on it is
#   still standing. Draft flags are ignored for past events (organisers forget
#   to tick "setup complete" on events that plainly happened), but a draft that
#   hasn't started yet is not announced on a public map.
# - A student is a distinct participant with a standing registration on a
#   counted event. Withdrawn and rejected registrations were never supported.
# - A country is a participant's country of residence, with the handful of ISO
#   codes and spellings people typed folded into one name.
class LandingStats
  CACHE_KEY = "landing_stats/v1".freeze
  TTL = 1.hour

  EXCLUDED_STATUSES = %w[withdrawn rejected].freeze

  # Residence is free text on the participant. These are the variants that
  # have actually shown up; anything else is counted under the name as typed.
  COUNTRY_ALIASES = {
    "US" => "United States",
    "USA" => "United States",
    "United State" => "United States",
    "United States of America" => "United States",
    "GB" => "United Kingdom",
    "UK" => "United Kingdom",
    "IN" => "India",
    "NP" => "Nepal",
    "AU" => "Australia",
    "PK" => "Pakistan",
    "CA" => "Canada",
    "DE" => "Germany",
    "FR" => "France",
    "România" => "Romania",
    "日本" => "Japan"
  }.freeze

  def self.fetch
    Rails.cache.fetch(CACHE_KEY, expires_in: TTL) { new.to_h }
  end

  def self.normalize_country(raw)
    name = raw.to_s.strip
    COUNTRY_ALIASES.fetch(name) { COUNTRY_ALIASES.fetch(name.upcase, name) }
  end

  def initialize(now: Time.current)
    @now = now
  end

  def to_h
    pins = build_pins
    index_by_event = pins.each_with_index.to_h { |pin, i| [ pin.delete(:event_id), i ] }

    {
      generated_at: @now,
      events: counted_event_ids.size,
      students: counted_registrations.distinct.count(:participant_id),
      countries: roll(index_by_event).size,
      roll: roll(index_by_event),
      pins: pins
    }
  end

  private

  def counted_registrations
    ParticipantEvent.joins(:event)
      .where(events: { starts_at: ..@now })
      .where.not(status: EXCLUDED_STATUSES)
  end

  def counted_event_ids
    @counted_event_ids ||= counted_registrations.distinct.pluck(:event_id)
  end

  # One row per country: distinct students, and which pins their students
  # went to (indexes into the pins array, so the page can light them up).
  def roll(index_by_event)
    @roll ||= begin
      residents = counted_registrations.joins(:participant)
        .where.not(participants: { country_of_residence: [ nil, "" ] })

      students = Hash.new(0)
      residents.group("participants.country_of_residence").distinct.count(:participant_id).each do |raw, n|
        students[self.class.normalize_country(raw)] += n
      end

      events = Hash.new { |h, k| h[k] = Set.new }
      residents.distinct.pluck("participants.country_of_residence", "participant_events.event_id").each do |raw, event_id|
        pin = index_by_event[event_id]
        events[self.class.normalize_country(raw)] << pin if pin
      end

      students.map { |name, n| { name: name, students: n, pins: events[name].sort } }
        .sort_by { |row| [ -row[:students], row[:name] ] }
    end
  end

  def build_pins
    counted = Event.where(id: counted_event_ids)
    announced = Event.where.not(setup_completed_at: nil).where("starts_at > ?", @now)
    headcounts = counted_registrations.group(:event_id).distinct.count(:participant_id)

    counted.or(announced)
      .where.not(location_latitude: nil).where.not(location_longitude: nil)
      .order(:starts_at)
      .map do |event|
        {
          event_id: event.id,
          name: event.name,
          location: [ event.location_city, event.location_country ].compact_blank.join(", "),
          dates: ApplicationController.helpers.event_date_range(event.starts_at, event.ends_at),
          lat: event.location_latitude.to_f.round(4),
          lon: event.location_longitude.to_f.round(4),
          students: headcounts.fetch(event.id, 0),
          state: state_for(event)
        }
      end
  end

  def state_for(event)
    return "upcoming" if event.starts_at > @now
    return "live" if event.ends_at.present? && event.ends_at >= @now

    "past"
  end
end
