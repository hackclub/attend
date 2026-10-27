# Server-side counterpart to the Places autocomplete on the venue form. The
# form captures a place id when an admin picks a venue; this covers venues
# that arrived via import or the API and the backfill of older events.
class GooglePlacesService
  BASE_URL = "https://places.googleapis.com".freeze
  MAX_DISTANCE_METRES = AppleMapsService::MAX_DISTANCE_METRES
  # locationBias is only a hint: a venue called "Wellington" near Crowthorne
  # came back as the city in New Zealand. A restriction keeps results in the
  # box, and the distance check below tightens it to a circle.
  RESTRICTION_DEGREES = 0.02

  class << self
    def configured?
      api_key.present?
    end

    def find_place(name:, latitude:, longitude:)
      return nil if name.blank? || latitude.blank? || longitude.blank?
      return nil unless configured?

      response = connection.post("/v1/places:searchText") do |r|
        r.headers["Content-Type"] = "application/json"
        r.headers["X-Goog-Api-Key"] = api_key
        r.headers["X-Goog-FieldMask"] = "places.id,places.displayName,places.location"
        r.body = {
          textQuery: name,
          locationRestriction: {
            rectangle: {
              low: { latitude: latitude.to_f - RESTRICTION_DEGREES, longitude: longitude.to_f - RESTRICTION_DEGREES },
              high: { latitude: latitude.to_f + RESTRICTION_DEGREES, longitude: longitude.to_f + RESTRICTION_DEGREES }
            }
          }
        }.to_json
      end
      return nil unless response.success?

      places = JSON.parse(response.body).fetch("places", [])
      match = places.find do |place|
        place["id"].present? && place["location"] &&
          AppleMapsService.distance_metres(latitude.to_f, longitude.to_f, place["location"]["latitude"], place["location"]["longitude"]) <= MAX_DISTANCE_METRES
      end
      return nil unless match

      {
        id: match["id"],
        name: match.dig("displayName", "text"),
        latitude: match["location"]["latitude"],
        longitude: match["location"]["longitude"]
      }
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.error("Google Places lookup failed for '#{name}': #{e.message}")
      nil
    end

    private

    def connection
      Faraday.new(BASE_URL)
    end

    def api_key
      ENV["GOOGLE_MAPS_API_KEY"].presence || Rails.application.credentials.dig(:google, :key)
    end
  end
end
