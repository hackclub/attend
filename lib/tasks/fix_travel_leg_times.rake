namespace :travel_legs do
  desc <<~DESC
    Repair TravelLeg departure/arrival dates that were collapsed onto a single
    day by the old flight-date merge (which stomped the arrival onto the
    departure's date, inverting every overnight/long-haul leg).

    Primary source is the OAG data already stored on the leg (no API calls):
    the scheduled UTC departure/arrival times carry the correct calendar dates.
    For legs with no stored OAG data, falls back to a safe heuristic: if the
    arrival is before the departure, roll the arrival forward a day.

    ENV:
      APPLY=1            actually write (default: dry run)
      EVENT=<slug>       limit to one event
      THRESHOLD_MINUTES  ignore drift under N minutes (default 2)
  DESC
  task fix_times: :environment do
    apply = ENV["APPLY"] == "1"
    event_slug = ENV["EVENT"]
    threshold_minutes = (ENV["THRESHOLD_MINUTES"] || "2").to_i

    scope = TravelLeg.where.not(departure_time: nil)
    if event_slug.present?
      event = Event.find_by!(slug: event_slug)
      scope = scope.joins(travel: { participant_event: :event }).where(events: { id: event.id })
    end

    legs = scope.to_a
    puts "Examining #{legs.size} legs (apply=#{apply}, threshold=±#{threshold_minutes}m, event=#{event_slug || 'all'})"

    fixed_from_oag = 0
    fixed_heuristic = 0
    already_ok = 0
    unfixable = 0
    errors = 0

    legs.each_with_index do |leg, idx|
      print "." if (idx % 25).zero?

      new_dep, new_arr, source = repaired_times(leg)

      if new_dep.nil? && new_arr.nil?
        # No OAG data. Heuristic: an arrival before its departure means the
        # arrival date was stomped back — roll it forward until it's after.
        if leg.arrival_time && leg.departure_time && leg.arrival_time < leg.departure_time
          rolled = leg.arrival_time
          rolled += 1.day while rolled < leg.departure_time
          new_arr = rolled
          source = :heuristic
        else
          unfixable += 1
          next
        end
      end

      dep_changed = new_dep && ((leg.departure_time - new_dep) / 60).round.abs > threshold_minutes
      arr_changed = new_arr && leg.arrival_time && ((leg.arrival_time - new_arr) / 60).round.abs > threshold_minutes
      arr_changed ||= new_arr && leg.arrival_time.nil?

      unless dep_changed || arr_changed
        already_ok += 1
        next
      end

      puts ""
      puts "leg #{leg.id} #{leg.flight_code} #{leg.departure_airport}->#{leg.arrival_airport} [#{source}]"
      puts "  stored  dep=#{leg.departure_time}  arr=#{leg.arrival_time}"
      puts "  fixed   dep=#{new_dep || leg.departure_time}  arr=#{new_arr || leg.arrival_time}"

      if apply
        attrs = {}
        attrs[:departure_time] = new_dep if dep_changed
        attrs[:arrival_time] = new_arr if arr_changed
        leg.update_columns(attrs) if attrs.any?
      end

      source == :heuristic ? (fixed_heuristic += 1) : (fixed_from_oag += 1)
    rescue StandardError => e
      errors += 1
      puts "\n  error leg=#{leg.id}: #{e.class}: #{e.message}"
    end

    puts ""
    puts "---"
    puts "fixed from OAG data: #{fixed_from_oag}#{apply ? ' (applied)' : ''}"
    puts "fixed (heuristic):   #{fixed_heuristic}#{apply ? ' (applied)' : ''}"
    puts "already ok:          #{already_ok}"
    puts "unfixable (no data): #{unfixable}"
    puts "errors:              #{errors}"
    puts apply ? "APPLIED changes." : "Dry run — re-run with APPLY=1 to write."
  end

  # Returns [departure_time, arrival_time, :oag] derived from the leg's stored
  # OAG data (true UTC, correct dates), or [nil, nil, nil] when unavailable.
  def repaired_times(leg)
    tracking = leg.live_tracking_data
    return [ nil, nil, nil ] if tracking.blank?

    dep = tracking[:scheduled_departure].presence && (Time.iso8601(tracking[:scheduled_departure]) rescue nil)
    arr = tracking[:scheduled_arrival].presence && (Time.iso8601(tracking[:scheduled_arrival]) rescue nil)
    return [ nil, nil, nil ] if dep.nil? && arr.nil?

    [ dep, arr, :oag ]
  end
end
