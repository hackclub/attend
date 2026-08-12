class OagFlightService
  BASE_URL = "https://api.oag.com".freeze
  FLIGHT_INSTANCES_URL = "#{BASE_URL}/flight-instances".freeze
  FLIGHT_CODE_REGEX = /\A([A-Z]{2,3}|\d[A-Z]|[A-Z]\d)(\d{1,4})\z/i

  # OAG state → FlightAware-style status (keeps FlightEta::RAW_STATUS_MAP
  # and the live_status == "Arrived" check working unchanged).
  STATE_MAP = {
    "Scheduled" => "Scheduled",
    "OutGate"   => "Departed",
    "InAir"     => "EnRoute",
    "Landed"    => "Arrived",
    "InGate"    => "Arrived",
    "Canceled"  => "Cancelled"
  }.freeze

  class << self
    def airport_timezone(iata_or_icao)
      AirportTimezones.lookup(iata_or_icao)
    end

    def fetch_flight_by_id(schedule_instance_key, departure_date:)
      return nil if schedule_instance_key.blank? || departure_date.blank?
      key = subscription_key
      return nil if key.blank?

      date = departure_date.is_a?(Date) ? departure_date : Date.parse(departure_date.to_s)
      response = oag_get("#{FLIGHT_INSTANCES_URL}/#{date.iso8601}/#{schedule_instance_key}", { Content: "Status", version: "v2" }, key)
      return nil unless response.success?

      JSON.parse(response.body)
    rescue Faraday::Error, JSON::ParserError, ArgumentError => e
      Rails.logger.error("[OagFlightService] fetch_flight_by_id error for #{schedule_instance_key}: #{e.message}")
      nil
    end

    def fetch_flight(flight_code, departure_date, destination_airport: nil, origin_airport: nil)
      flights = fetch_all_flights(flight_code, departure_date)
      return nil if flights.blank?

      find_by_route(flights, origin_airport, destination_airport) || flights.first
    end

    def fetch_all_flights(flight_code, departure_date)
      return [] if flight_code.blank? || departure_date.blank?
      key = subscription_key
      return [] if key.blank?

      normalized = flight_code.to_s.strip.upcase.gsub(/\s+/, "")
      match = normalized.match(FLIGHT_CODE_REGEX)
      return [] unless match
      carrier_code, flight_number = match[1], match[2]
      date = departure_date.is_a?(Date) ? departure_date : Date.parse(departure_date.to_s)

      response = oag_get(
        "#{FLIGHT_INSTANCES_URL}/",
        {
          CarrierCode: carrier_code,
          FlightNumber: flight_number,
          DepartureDateTime: date.iso8601,
          Content: "Status",
          CodeType: "IATA,ICAO",
          version: "v2"
        },
        key
      )
      return [] unless response.success?
      JSON.parse(response.body)["data"] || []
    rescue Faraday::Error, JSON::ParserError, ArgumentError => e
      Rails.logger.error("[OagFlightService] fetch_all_flights error for #{flight_code} #{departure_date}: #{e.message}")
      []
    end

    # A multi-stop flight number returns several instances (each segment plus
    # the origin-to-terminus through-flight, whose times are the origin's).
    # Matching on destination alone can pick the through-flight and report the
    # wrong departure, so prefer an instance matching both endpoints.
    def find_by_route(flights, origin_airport, destination_airport)
      candidates = destination_airport.present? ? flights.select { |f| airport_match?(f, "arrival", destination_airport) } : flights
      return nil if candidates.empty?

      if origin_airport.present?
        exact = candidates.find { |f| airport_match?(f, "departure", origin_airport) }
        return exact if exact
      end

      destination_airport.present? ? candidates.first : nil
    end

    def find_by_destination(flights, destination_airport)
      find_by_route(flights, nil, destination_airport)
    end

    def airport_match?(flight, direction, code)
      ap = flight.dig(direction, "airport") || {}
      code_upper = code.to_s.upcase
      [ ap["iata"], ap["icao"], ap["faa"] ].compact.any? { |c| c.upcase == code_upper }
    end

    def parse_flight_summary(data)
      return nil if data.blank?

      departure = data["departure"] || {}
      arrival = data["arrival"] || {}
      status = latest_status(data)

      scheduled_departure = combine_date_time(departure["date"], departure["time"], :utc)
      scheduled_arrival   = combine_date_time(arrival["date"], arrival["time"], :utc)

      actual_out = status_time(status, :departure, :actualTime, :outGate, scheduled_departure)
      actual_in  = status_time(status, :arrival, :actualTime, :inGate, scheduled_arrival)
      estimated_in = status_time(status, :arrival, :estimatedTime, :inGate, scheduled_arrival)

      carrier = data["carrier"] || {}

      {
        status: determine_status(data, status),
        departure_airport_iata: departure.dig("airport", "iata"),
        arrival_airport_iata:   arrival.dig("airport", "iata"),
        scheduled_departure: scheduled_departure&.iso8601,
        scheduled_arrival:   scheduled_arrival&.iso8601,
        local_departure_time: combine_local(departure["date"], departure["time"]),
        local_arrival_time:   combine_local(arrival["date"], arrival["time"]),
        aircraft_type: data.dig("aircraftType", "iata") || data.dig("aircraftType", "icao"),
        airline_name:  carrier["iata"] || carrier["icao"]
      }
    end

    def parse_flight_data(data)
      summary = parse_flight_summary(data)
      return nil if summary.nil?

      departure = data["departure"] || {}
      arrival = data["arrival"] || {}
      status = latest_status(data)
      carrier = data["carrier"] || {}

      scheduled_departure = combine_date_time(departure["date"], departure["time"], :utc)
      scheduled_arrival   = combine_date_time(arrival["date"], arrival["time"], :utc)
      actual_out = status_time(status, :departure, :actualTime, :outGate, scheduled_departure)
      actual_in  = status_time(status, :arrival, :actualTime, :inGate, scheduled_arrival)
      estimated_in = status_time(status, :arrival, :estimatedTime, :inGate, scheduled_arrival)

      summary.merge(
        departure_airport_icao: departure.dig("airport", "icao") || departure.dig("airport", "iata"),
        arrival_airport_icao:   arrival.dig("airport", "icao") || arrival.dig("airport", "iata"),
        actual_departure: actual_out&.iso8601,
        predicted_arrival: (estimated_in || actual_in)&.iso8601,
        terminal: departure["terminal"] || status&.dig("departure", "actualTerminal"),
        gate: status&.dig("departure", "gate"),
        arrival_terminal: arrival["terminal"] || status&.dig("arrival", "actualTerminal"),
        arrival_gate: status&.dig("arrival", "gate"),
        registration: status&.dig("equipment", "aircraftRegistrationNumber"),
        flight_number: "#{carrier['iata'] || carrier['icao']}#{data['flightNumber']}",
        airline_iata: carrier["iata"],
        airline_icao: carrier["icao"],
        schedule_instance_key: data["scheduleInstanceKey"]
      )
    end

    def status_color(status)
      case status
      when "Scheduled" then "gray"
      when "Departed", "EnRoute" then "blue"
      when "Arrived" then "green"
      when "Cancelled" then "red"
      when "Delayed" then "yellow"
      when "Diverted" then "orange"
      else "gray"
      end
    end

    def status_label(status)
      case status
      when "EnRoute" then "In Flight"
      else status || "Unknown"
      end
    end

    private

    def oag_get(url, params, key, retry_on_429: true)
      attempts = 0
      loop do
        response = Faraday.get(url, params, { "Subscription-Key" => key })
        return response unless response.status == 429
        return response unless retry_on_429
        attempts += 1
        return response if attempts > 3
        delay = (response.headers["Retry-After"]&.to_i || 0)
        delay = 2**attempts if delay <= 0
        Rails.logger.warn("[OagFlightService] 429 from #{url}, sleeping #{delay}s (attempt #{attempts})")
        sleep delay
      end
    end

    # Picks the most-recent statusDetails entry (by updatedAt).
    def latest_status(data)
      entries = data["statusDetails"]
      return nil if entries.blank?
      entries.max_by { |e| e["updatedAt"].to_s }
    end

    def determine_status(data, status)
      return "Diverted" if status && status["diversionAirport"].present?
      state = status && status["state"]
      STATE_MAP[state] || "Scheduled"
    end

    # Build an ISO8601 UTC time from OAG's split Date+Time objects.
    def combine_date_time(date_obj, time_obj, kind)
      return nil if date_obj.blank? || time_obj.blank?
      date_str = date_obj[kind.to_s]
      time_str = time_obj[kind.to_s]
      return nil if date_str.blank? || time_str.blank?
      Time.utc(*Date.parse(date_str).then { |d| [ d.year, d.month, d.day ] },
               *time_str.split(":").map(&:to_i))
    rescue ArgumentError, TypeError
      nil
    end

    # Formats local time as "YYYY-MM-DD HH:MM" — used by UI as a fallback when no tz is known.
    def combine_local(date_obj, time_obj)
      return nil if date_obj.blank? || time_obj.blank?
      d = date_obj["local"]
      t = time_obj["local"]
      return nil if d.blank? || t.blank?
      "#{d} #{t}"
    end

    # OAG status time fields are HH:mm only (no date). Anchor to the
    # scheduled time and roll the date if the diff exceeds 12h either way.
    def status_time(status, direction, kind, gate, anchor)
      return nil if status.blank? || anchor.blank?
      hhmm = status.dig(direction.to_s, kind.to_s, gate.to_s, "utc")
      return nil if hhmm.blank?
      h, m = hhmm.split(":").map(&:to_i)
      candidate = Time.utc(anchor.year, anchor.month, anchor.day, h, m)
      diff = candidate - anchor
      candidate += 86400 if diff < -12 * 3600
      candidate -= 86400 if diff >  12 * 3600
      candidate
    rescue ArgumentError, TypeError
      nil
    end

    def subscription_key
      ENV["OAG_SUBSCRIPTION_KEY"] || Rails.application.credentials.dig(:oag, :subscription_key)
    end
  end

  module AirportTimezones
    PATH = Rails.root.join("config/airport_timezones.yml")

    def self.lookup(code)
      return nil if code.blank?
      normalized = code.to_s.strip.upcase
      data[normalized]
    end

    def self.data
      @data ||= File.exist?(PATH) ? YAML.load_file(PATH).transform_keys { |k| k.to_s.upcase } : {}
    end

    def self.reset!
      @data = nil
    end
  end
end
