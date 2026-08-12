module TravelLegDateMerging
  extend ActiveSupport::Concern

  private

  # Flight legs are entered manually. Each leg carries wall-clock departure and
  # arrival datetimes (`datetime-local` inputs) plus an optional timezone pick
  # (`departure_time_zone` / `arrival_time_zone`). A blank pick means "derive
  # from the airport" (via config/airport_timezones.yml).
  #
  # We interpret each wall-clock time in its zone and store true UTC, so a leg
  # that departs in one zone and arrives in another (overnight/long-haul) keeps
  # both endpoints correct. The `*_time_zone` params are stripped here since
  # they aren't columns on TravelLeg.
  def normalize_leg_times!(travel_params)
    return unless travel_params[:travel_legs_attributes].present?

    travel_params[:travel_legs_attributes].each do |_index, leg_attrs|
      apply_leg_zone!(leg_attrs, :departure_time, :departure_time_zone, leg_attrs[:departure_airport])
      apply_leg_zone!(leg_attrs, :arrival_time, :arrival_time_zone, leg_attrs[:arrival_airport])
    end
  end

  def apply_leg_zone!(leg_attrs, time_key, zone_key, airport_code)
    picked = leg_attrs.delete(zone_key)
    raw = leg_attrs[time_key]
    return if raw.blank?

    zone = ActiveSupport::TimeZone[picked.to_s] if picked.present?
    zone ||= airport_time_zone(airport_code)
    zone ||= Time.zone

    parsed = (zone.parse(raw.to_s) rescue nil)
    leg_attrs[time_key] = parsed.utc.iso8601 if parsed
  end

  def airport_time_zone(code)
    name = FlightTrackingService.airport_timezone(code)
    name && ActiveSupport::TimeZone[name]
  end
end
