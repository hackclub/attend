module Exports
  # Flattens a plane travel's legs into a single summary string,
  # e.g. "AA123 SFO→ORD 2026-07-01 08:00 PDT; UA456 ORD→BOS 2026-07-01 14:05 CDT"
  class LegSummary
    def self.call(travel)
      return nil unless travel&.plane?

      summaries = travel.travel_legs.sort_by { |leg| leg.position.to_i }.map do |leg|
        [
          leg.flight_code,
          [ leg.departure_airport, leg.arrival_airport ].compact.join("→").presence,
          leg.local_departure_time&.strftime("%Y-%m-%d %H:%M %Z")
        ].compact.join(" ")
      end

      summaries.reject(&:blank?).join("; ").presence
    end
  end
end
