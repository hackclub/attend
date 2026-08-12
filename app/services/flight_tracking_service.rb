class FlightTrackingService
  class << self
    delegate :fetch_flight, :fetch_flight_by_id, :fetch_all_flights, :parse_flight_data, :parse_flight_summary,
             :airport_timezone, :status_color, :status_label,
             to: OagFlightService
  end
end
