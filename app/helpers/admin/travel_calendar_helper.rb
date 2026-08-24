module Admin::TravelCalendarHelper
  # Flight leg times are stored in true UTC (from OAG). Render them in the
  # relevant airport's local timezone so the displayed time matches the ticket.
  # Falls back to UTC when the airport's timezone isn't known.
  def flight_local_time(time, airport_code, format: "%b %d, %Y %H:%M")
    return nil if time.blank?

    timezone = FlightTrackingService.airport_timezone(airport_code)
    (timezone ? time.in_time_zone(timezone) : time).strftime(format)
  end
end
