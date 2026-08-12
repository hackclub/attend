class AeroDataBoxService
  BASE_URL = "https://aerodatabox.p.rapidapi.com".freeze

  class << self
    def fetch_flight(flight_code, departure_date, destination_airport: nil)
      flights = fetch_all_flights(flight_code, departure_date)
      return nil if flights.blank?

      if destination_airport.present?
        dest_upper = destination_airport.upcase
        flights.find do |f|
          arrival_iata = f.dig("arrival", "airport", "iata")
          arrival_iata&.upcase == dest_upper
        end || flights.first
      else
        flights.first
      end
    end

    def fetch_all_flights(flight_code, departure_date)
      return [] if flight_code.blank? || departure_date.blank?

      api_key = rapidapi_key
      return [] if api_key.blank?

      flight_number = normalize_flight_number(flight_code)
      date = departure_date.is_a?(Date) ? departure_date : Date.parse(departure_date.to_s)

      response = Faraday.get(
        "#{BASE_URL}/flights/number/#{flight_number}/#{date.iso8601}",
        {},
        {
          "x-rapidapi-key" => api_key,
          "x-rapidapi-host" => "aerodatabox.p.rapidapi.com"
        }
      )

      return [] unless response.success?

      flights = JSON.parse(response.body)
      return [] if flights.blank? || !flights.is_a?(Array)

      flights
    rescue Faraday::Error, JSON::ParserError, URI::InvalidURIError => e
      Rails.logger.error("[AeroDataBoxService] Error fetching flight #{flight_code}: #{e.message}")
      []
    end

    def parse_flight_data(data)
      return nil if data.blank?

      departure = data["departure"] || {}
      arrival = data["arrival"] || {}
      departure_airport = departure["airport"] || {}
      arrival_airport = arrival["airport"] || {}

      status = determine_status(data)

      departure_coords = extract_coordinates(departure_airport)
      arrival_coords = extract_coordinates(arrival_airport)

      {
        status: status,
        departure_airport_iata: departure_airport["iata"],
        departure_airport_icao: departure_airport["icao"],
        departure_airport_name: departure_airport["name"],
        arrival_airport_iata: arrival_airport["iata"],
        arrival_airport_icao: arrival_airport["icao"],
        arrival_airport_name: arrival_airport["name"],
        scheduled_departure: departure.dig("scheduledTime", "utc"),
        actual_departure: departure.dig("actualTime", "utc") || departure.dig("revisedTime", "utc"),
        scheduled_arrival: arrival.dig("scheduledTime", "utc"),
        predicted_arrival: arrival.dig("predictedTime", "utc") || arrival.dig("actualTime", "utc"),
        local_departure_time: departure.dig("scheduledTime", "local"),
        local_arrival_time: arrival.dig("scheduledTime", "local"),
        departure_coordinates: departure_coords,
        arrival_coordinates: arrival_coords,
        terminal: departure["terminal"],
        gate: departure["gate"],
        arrival_terminal: arrival["terminal"],
        arrival_gate: arrival["gate"],
        aircraft_type: data.dig("aircraft", "model"),
        registration: data.dig("aircraft", "reg"),
        flight_number: data["number"],
        airline_name: data.dig("airline", "name"),
        airline_iata: data.dig("airline", "iata"),
        airline_icao: data.dig("airline", "icao"),
        data_source: "AeroDataBox"
      }
    end

    def search_airports(keyword)
      return [] if keyword.blank? || keyword.length < 2

      api_key = rapidapi_key
      return [] if api_key.blank?

      response = Faraday.get(
        "#{BASE_URL}/airports/search/term",
        { q: keyword, limit: 10 },
        {
          "x-rapidapi-key" => api_key,
          "x-rapidapi-host" => "aerodatabox.p.rapidapi.com"
        }
      )

      return [] unless response.success?

      result = JSON.parse(response.body)
      items = result["items"] || []

      items.map do |airport|
        {
          iata: airport["iata"],
          icao: airport["icao"],
          name: airport["name"],
          city: airport["municipalityName"],
          country: airport["countryCode"],
          location: airport["location"]
        }
      end
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.error("[AeroDataBoxService] Error searching airports: #{e.message}")
      []
    end

    def get_airport(code)
      return nil if code.blank?

      api_key = rapidapi_key
      return nil if api_key.blank?

      code_type = code.length == 4 ? "icao" : "iata"

      response = Faraday.get(
        "#{BASE_URL}/airports/#{code_type}/#{code.upcase}",
        {},
        {
          "x-rapidapi-key" => api_key,
          "x-rapidapi-host" => "aerodatabox.p.rapidapi.com"
        }
      )

      return nil unless response.success?

      JSON.parse(response.body)
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.error("[AeroDataBoxService] Error fetching airport #{code}: #{e.message}")
      nil
    end

    def status_color(status)
      case status
      when "Scheduled", "Expected" then "gray"
      when "Departed", "EnRoute" then "blue"
      when "Arrived", "Landed", "Arrived / Gate Arrival" then "green"
      when "Cancelled", "Canceled" then "red"
      when "Delayed" then "yellow"
      when "Diverted" then "orange"
      else "gray"
      end
    end

    def status_label(status)
      case status
      when "EnRoute" then "In Flight"
      when "Expected" then "Scheduled"
      else status || "Unknown"
      end
    end

    private

    def normalize_flight_number(flight_code)
      flight_code.to_s.strip.upcase.gsub(/[^A-Z0-9]/, "")
    end

    def determine_status(data)
      status = data["status"]
      return status if status.present?

      if data.dig("arrival", "actualTime", "utc").present?
        "Arrived"
      elsif data.dig("departure", "actualTime", "utc").present?
        "EnRoute"
      else
        "Scheduled"
      end
    end

    def extract_coordinates(airport_data)
      return nil if airport_data.blank?

      location = airport_data["location"]
      return nil if location.blank?

      {
        "lat" => location["lat"],
        "lon" => location["lon"]
      }
    end

    def rapidapi_key
      ENV["RAPIDAPI_KEY"] || Rails.application.credentials.send(:"rapidapi-key")
    end
  end
end
