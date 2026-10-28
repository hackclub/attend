# Looks venues up in Apple Maps so we can store their Place ID alongside the
# coordinates we already geocode. Only points of interest carry an id, so we
# search by venue name near the coordinates and keep the hit only when it
# lands close to where we think the venue is.
#
# Auth is a two-step: sign a short-lived JWT with the Maps key from the
# developer portal, then swap it for an access token that lasts ~30 minutes.
class AppleMapsService
  BASE_URL = "https://maps-api.apple.com".freeze
  TOKEN_CACHE_KEY = "apple_maps:access_token".freeze
  TOKEN_TTL = 25.minutes
  # Our coordinates usually come from a street-address geocode and Apple's
  # pin sits on the building; anything further than this is a different place.
  MAX_DISTANCE_METRES = 1_000

  class << self
    def configured?
      key_id.present? && private_key.present? && team_id.present?
    end

    # Returns { id:, name:, latitude:, longitude: } for the closest matching
    # point of interest, or nil.
    def find_place(name:, latitude:, longitude:)
      return nil if name.blank? || latitude.blank? || longitude.blank?
      return nil unless configured?

      response = connection.get("/v1/search", {
        q: name,
        searchLocation: "#{latitude},#{longitude}",
        resultTypeFilter: "Poi"
      }) { |r| r.headers["Authorization"] = "Bearer #{access_token}" }
      return nil unless response.success?

      results = JSON.parse(response.body).fetch("results", [])
      match = results.find do |place|
        place["id"].present? && place["coordinate"] &&
          distance_metres(latitude.to_f, longitude.to_f, place["coordinate"]["latitude"], place["coordinate"]["longitude"]) <= MAX_DISTANCE_METRES
      end
      return nil unless match

      {
        id: match["id"],
        name: match["name"],
        latitude: match["coordinate"]["latitude"],
        longitude: match["coordinate"]["longitude"]
      }
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.error("Apple Maps lookup failed for '#{name}': #{e.message}")
      nil
    end

    def access_token
      Rails.cache.fetch(TOKEN_CACHE_KEY, expires_in: TOKEN_TTL) do
        response = connection.get("/v1/token") { |r| r.headers["Authorization"] = "Bearer #{auth_token}" }
        raise Faraday::ClientError, "Apple Maps token exchange failed (#{response.status})" unless response.success?

        JSON.parse(response.body).fetch("accessToken")
      end
    end

    # ES256 JWT, signed by hand: the signature has to be the raw r||s pair,
    # not the DER that OpenSSL hands back.
    def auth_token(now: Time.current)
      header = base64url({ alg: "ES256", kid: key_id, typ: "JWT" }.to_json)
      payload = base64url({ iss: team_id, iat: now.to_i, exp: now.to_i + 1.hour }.to_json)
      signing_input = "#{header}.#{payload}"

      der = OpenSSL::PKey::EC.new(private_key).sign(OpenSSL::Digest.new("SHA256"), signing_input)
      r, s = OpenSSL::ASN1.decode(der).value.map { |v| v.value.to_s(2).rjust(32, "\0") }

      "#{signing_input}.#{base64url(r + s)}"
    end

    def distance_metres(lat1, lon1, lat2, lon2)
      rad = Math::PI / 180
      dlat = (lat2 - lat1) * rad
      dlon = (lon2 - lon1) * rad
      a = Math.sin(dlat / 2)**2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlon / 2)**2
      6_371_000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    end

    private

    def connection
      Faraday.new(BASE_URL)
    end

    def base64url(string)
      Base64.urlsafe_encode64(string, padding: false)
    end

    def credentials
      Rails.application.credentials.dig(:apple_maps) || {}
    end

    def key_id
      ENV["APPLE_MAPS_KEY_ID"].presence || credentials[:key_id]
    end

    def private_key
      ENV["APPLE_MAPS_PRIVATE_KEY"].presence || credentials[:private_key]
    end

    # The Maps key belongs to the same developer team as the Wallet pass
    # certificate, so fall back to that rather than storing the id twice.
    def team_id
      ENV["APPLE_MAPS_TEAM_ID"].presence || credentials[:team_id] ||
        Rails.application.credentials.dig(:passkit, :apple_team_identifier)
    end
  end
end
