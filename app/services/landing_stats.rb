# Live numbers and map pins for the signed-out front door.
#
# The page states how many hackathons Attend has run, how many students it has
# supported and from how many countries, and plots every event on a map. All of
# it comes from the database so it can never go stale, and all of it is held in
# the cache for an hour so the busiest unauthenticated route never runs a count
# per request.
#
# What counts, and why:
# - An event counts once it has started and at least one person on it has been
#   scanned in at a check-in point. Draft flags are ignored for the headline (organisers forget
#   to tick "setup complete" on events that plainly happened), but only events
#   that finished setup are placed on the map: a draft was never announced, so
#   its venue is not public either. Events an import brought in (Envoy's, for
#   their visa letters) never count: Attend didn't run them.
# - A student is a distinct participant who was scanned in at a check-in point
#   on a counted event. A registration nobody scanned is someone who signed up,
#   not someone who turned up, so it stays out of every number on the page.
# - A country is a participant's country of residence, with the handful of ISO
#   codes and spellings people typed folded into one name. Only names the
#   product offers are published: residence was free text for a long time, and
#   a value nobody else typed could point at one person.
class LandingStats
  CACHE_KEY = "landing_stats/v2".freeze
  TTL = 1.hour

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
    "HK" => "Hong Kong",
    "România" => "Romania",
    "日本" => "Japan"
  }.freeze

  # The picker's list, plus territories people actually live in that it leaves
  # out. Anything else is left out of the count rather than published as typed.
  KNOWN_COUNTRIES = (ApplicationHelper::COUNTRIES.without("---") + [
    "Hong Kong", "Macau", "Puerto Rico", "Guam", "Bermuda", "Cayman Islands", "Anguilla",
    "Gibraltar", "Greenland", "Faroe Islands", "Isle of Man", "Jersey", "Guernsey",
    "Aruba", "Curaçao", "Réunion", "French Polynesia", "New Caledonia",
    "British Virgin Islands", "U.S. Virgin Islands", "Turks and Caicos Islands", "Montserrat"
  ]).to_set.freeze

  # Map pins are rounded to about a kilometre. The map never zooms past the
  # country level, so nothing is lost, and the exact venue stays off the page.
  COORDINATE_DECIMALS = 2

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
    {
      events: counted_event_ids.size,
      students: counted_registrations.distinct.count(:participant_id),
      countries: countries.size,
      pins: build_pins
    }
  end

  private

  def counted_registrations
    ParticipantEvent.joins(:event).merge(Event.not_imported)
      .where(events: { starts_at: ..@now })
      .where(id: Scan.for_check_in.select(:participant_event_id))
  end

  def counted_event_ids
    @counted_event_ids ||= counted_registrations.distinct.pluck(:event_id)
  end

  # Distinct countries of residence across counted students, folded and
  # filtered to names the product offers.
  def countries
    counted_registrations.joins(:participant)
      .where.not(participants: { country_of_residence: [ nil, "" ] })
      .distinct.pluck("participants.country_of_residence")
      .map { |raw| self.class.normalize_country(raw) }
      .to_set & KNOWN_COUNTRIES
  end

  def build_pins
    counted = Event.where(id: counted_event_ids)
    announced = Event.not_imported.where("starts_at > ?", @now)
    headcounts = counted_registrations.group(:event_id).distinct.count(:participant_id)

    counted.or(announced)
      .where.not(setup_completed_at: nil)
      .where.not(location_latitude: nil).where.not(location_longitude: nil)
      .order(:starts_at)
      .map do |event|
        {
          name: event.name,
          location: [ event.location_city, event.location_country ].compact_blank.join(", "),
          dates: ApplicationController.helpers.event_date_range(event.starts_at, event.ends_at),
          lat: event.location_latitude.to_f.round(COORDINATE_DECIMALS),
          lon: event.location_longitude.to_f.round(COORDINATE_DECIMALS),
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
