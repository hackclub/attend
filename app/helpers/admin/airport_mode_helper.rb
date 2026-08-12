module Admin::AirportModeHelper
  FLIGHT_REPORT_FORM_URL = "https://forms.hackclub.com/t/hBHnGAJaemus".freeze

  # Flight leg times are stored in true UTC (from OAG). Render them in the
  # relevant airport's local timezone so the displayed time matches the ticket.
  # Falls back to UTC when the airport's timezone isn't known.
  def flight_local_time(time, airport_code, format: "%b %d, %Y %H:%M")
    return nil if time.blank?
    tz = FlightTrackingService.airport_timezone(airport_code)
    (tz ? time.in_time_zone(tz) : time).strftime(format)
  end

  # Builds a prefilled Fillout URL for reporting bad flight data on a leg.
  def flight_report_url(leg:, event:, user:, source_url:, participant_name: nil)
    params = {
      leg_id: leg[:id],
      event_slug: event.slug,
      participant_name: participant_name || leg[:participant_name],
      flight_code: leg[:flight_code],
      route: "#{leg[:departure_airport]} → #{leg[:arrival_airport]}",
      departure_date: leg[:scheduled_departure_iso]&.then { |iso| Time.iso8601(iso).to_date.iso8601 },
      displayed_status: leg[:raw_status] || leg[:status_label],
      displayed_eta: leg[:eta_iso],
      displayed_gate: [ leg[:departure_terminal], leg[:departure_gate] ].compact.join("/"),
      oag_schedule_instance_key: leg[:oag_schedule_instance_key],
      last_tracked_at: leg[:last_tracked_at]&.iso8601,
      reporter_email: user&.email,
      source_url: source_url
    }.compact_blank
    "#{FLIGHT_REPORT_FORM_URL}?#{params.to_query}"
  end
end
