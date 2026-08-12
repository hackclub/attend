class AmadeusAirportService
  PRODUCTION_BASE_URL = "https://api.amadeus.com".freeze
  TEST_BASE_URL = "https://test.api.amadeus.com".freeze

  class << self
    def search_airports(keyword)
      return [] if keyword.blank? || keyword.length < 2

      access_token = get_access_token
      return [] if access_token.blank?

      upper_keyword = keyword.upcase.strip
      locations = []

      if upper_keyword.match?(/^[A-Z]{3}$/)
        iata_location = fetch_by_iata(upper_keyword, access_token)
        locations << iata_location if iata_location
      end

      keyword_results = search_by_keyword(keyword, access_token)
      keyword_results.each do |loc|
        locations << loc unless locations.any? { |l| l[:iata] == loc[:iata] }
      end

      locations.first(10)
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.error("[AmadeusAirportService] Error searching airports: #{e.message}")
      []
    end

    def fetch_by_iata(iata_code, access_token)
      response = Faraday.get(
        "#{base_url}/v1/reference-data/locations",
        {
          subType: "AIRPORT",
          keyword: iata_code,
          "page[limit]": 5
        },
        { "Authorization" => "Bearer #{access_token}" }
      )

      return nil unless response.success?

      result = JSON.parse(response.body)
      data = result["data"] || []
      exact_match = data.find { |loc| loc["iataCode"] == iata_code }
      exact_match ? parse_location(exact_match) : nil
    rescue Faraday::Error, JSON::ParserError
      nil
    end

    def search_by_keyword(keyword, access_token)
      response = Faraday.get(
        "#{base_url}/v1/reference-data/locations",
        {
          subType: "AIRPORT",
          keyword: keyword,
          "page[limit]": 10,
          sort: "analytics.travelers.score",
          view: "LIGHT"
        },
        { "Authorization" => "Bearer #{access_token}" }
      )

      return [] unless response.success?

      result = JSON.parse(response.body)
      (result["data"] || [])
        .select { |loc| loc["subType"] == "AIRPORT" }
        .map { |location| parse_location(location) }
    rescue Faraday::Error, JSON::ParserError
      []
    end

    def validate_airport(iata_code)
      return false if iata_code.blank?

      access_token = get_access_token
      return false if access_token.blank?

      response = Faraday.get(
        "#{base_url}/v1/reference-data/locations/#{iata_code.upcase}",
        {},
        { "Authorization" => "Bearer #{access_token}" }
      )

      response.success?
    rescue Faraday::Error => e
      Rails.logger.error("[AmadeusAirportService] Error validating airport: #{e.message}")
      false
    end

    def validate_flight(flight_code, departure_date)
      return { valid: false, error: "Flight code is required" } if flight_code.blank?

      carrier_code, flight_number = parse_flight_code(flight_code)
      return { valid: false, error: "Invalid flight code format" } if carrier_code.blank? || flight_number.blank?

      airline = AirlineDataService.lookup(carrier_code)
      airline_info = airline || { code: carrier_code, name: carrier_code, logo_url: AirlineDataService.logo_url(carrier_code) }

      return { valid: false, error: "Departure date is required", airline: airline_info } if departure_date.blank?

      access_token = get_access_token
      if access_token.blank?
        return {
          valid: false,
          error: "API unavailable - enter airports manually",
          airline: airline_info,
          flight_code: flight_code.upcase.gsub(/\s+/, ""),
          carrier: carrier_code,
          number: flight_number
        }
      end

      date_str = departure_date.is_a?(Date) ? departure_date.iso8601 : departure_date.to_s.split("T").first

      response = Faraday.get(
        "#{base_url}/v2/schedule/flights",
        {
          carrierCode: carrier_code,
          flightNumber: flight_number,
          scheduledDepartureDate: date_str
        },
        { "Authorization" => "Bearer #{access_token}" }
      )

      unless response.success?
        return {
          valid: false,
          error: "Flight not found",
          airline: airline_info,
          flight_code: flight_code.upcase.gsub(/\s+/, ""),
          carrier: carrier_code,
          number: flight_number
        }
      end

      result = JSON.parse(response.body)
      flights = result["data"] || []

      if flights.any?
        flight = flights.first
        flight_points = flight["flightPoints"] || []
        departure_point = flight_points.first || {}
        arrival_point = flight_points.last || {}

        departure_iata = departure_point["iataCode"]
        arrival_iata = arrival_point["iataCode"]

        departure_time = departure_point.dig("departure", "timings")&.find { |t| t["qualifier"] == "STD" }&.dig("value")
        arrival_time = arrival_point.dig("arrival", "timings")&.find { |t| t["qualifier"] == "STA" }&.dig("value")

        {
          valid: true,
          flight_code: flight_code.upcase.gsub(/\s+/, ""),
          departure_airport: departure_iata,
          arrival_airport: arrival_iata,
          departure_time: departure_time,
          arrival_time: arrival_time,
          carrier: carrier_code,
          number: flight_number,
          airline: airline_info
        }
      else
        {
          valid: false,
          error: "Flight not found for this date",
          airline: airline_info,
          flight_code: flight_code.upcase.gsub(/\s+/, ""),
          carrier: carrier_code,
          number: flight_number
        }
      end
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.error("[AmadeusAirportService] Error validating flight: #{e.message}")
      {
        valid: false,
        error: "Unable to validate flight",
        airline: airline_info,
        carrier: carrier_code,
        number: flight_number
      }
    end

    private

    def parse_location(data)
      {
        iata: data["iataCode"],
        name: data["name"],
        city: data.dig("address", "cityName"),
        country: data.dig("address", "countryName"),
        type: data["subType"]
      }
    end

    def parse_flight_code(flight_code)
      return [ nil, nil ] if flight_code.blank?

      cleaned = flight_code.to_s.strip.upcase.gsub(/\s+/, "")
      match = cleaned.match(/^([A-Z]{2}|\d[A-Z]|[A-Z]\d)(\d+)$/)
      return [ nil, nil ] unless match

      [ match[1], match[2] ]
    end

    def get_access_token
      cache_key = "amadeus_access_token"
      cached_token = Rails.cache.read(cache_key)
      return cached_token if cached_token.present?

      client_id = amadeus_client_id
      client_secret = amadeus_client_secret
      return nil if client_id.blank? || client_secret.blank?

      response = Faraday.post("#{base_url}/v1/security/oauth2/token") do |req|
        req.headers["Content-Type"] = "application/x-www-form-urlencoded"
        req.body = URI.encode_www_form(
          grant_type: "client_credentials",
          client_id: client_id,
          client_secret: client_secret
        )
      end

      return nil unless response.success?

      token_data = JSON.parse(response.body)
      access_token = token_data["access_token"]
      expires_in = token_data["expires_in"].to_i - 60

      Rails.cache.write(cache_key, access_token, expires_in: expires_in.seconds) if access_token.present?

      access_token
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.error("[AmadeusAirportService] OAuth error: #{e.message}")
      nil
    end

    def amadeus_client_id
      ENV["AMADEUS_CLIENT_ID"] || Rails.application.credentials.dig(:amadeus, :client_id)
    end

    def amadeus_client_secret
      ENV["AMADEUS_CLIENT_SECRET"] || Rails.application.credentials.dig(:amadeus, :client_secret)
    end

    def base_url
      production_mode? ? PRODUCTION_BASE_URL : TEST_BASE_URL
    end

    def production_mode?
      ENV["AMADEUS_PRODUCTION"] == "true" || Rails.env.production?
    end
  end
end
