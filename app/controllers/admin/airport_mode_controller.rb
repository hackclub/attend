module Admin
  class AirportModeController < BaseController
    before_action :require_event_selected
    before_action :require_travel_enabled

    ARRIVING_NOW_WINDOW = 30.minutes

    def show
      load_flights_data

      @tab = params[:tab].presence_in(%w[inbound outbound]) || "inbound"
      @view = params[:view].presence_in(%w[board grid]) || "board"
      @journeys = @tab == "outbound" ? @outbound_journeys : @inbound_journeys
      @journeys = @journeys.sort_by { |j| j[:primary_time_at] || far_future }

      @selected_group = current_event.groups_enabled? && params[:group_id].present? ?
        current_event.groups.find_by(id: params[:group_id]) : nil
      if @selected_group
        sg_id = @selected_group.id
        @journeys = @journeys.select { |j| j[:groups].any? { |g| g[:id] == sg_id } }
      end

      # The journeys come from a cached hash, so the collect-time includes can't
      # serve the view. Batch-load participants (with headshot blobs) once here
      # instead of one Participant.find + attachment lookup per rendered row.
      @participants_by_id = Participant
        .where(id: @journeys.map { |j| j[:participant_id] }.compact.uniq)
        .includes(headshot_attachment: :blob)
        .index_by(&:id)

      @summary_counts = build_summary_counts(@inbound_journeys, :inbound)
      @outbound_summary_counts = build_summary_counts(@outbound_journeys, :outbound)

      @airports_for_filter = @journeys
        .map { |j| j[:primary_airport_iata] }.compact.uniq.sort
      @terminals_for_filter = @journeys
        .map { |j| j[:primary_terminal] }.compact.uniq.sort

      @journeys_by_airport = @journeys
        .group_by { |j| j[:primary_airport_iata] || "—" }
        .transform_values { |list| list.sort_by { |j| j[:primary_time_at] || far_future } }
        .sort_by { |airport, _| airport }
    end
    helper_method :selected_group_in_airport

    def selected_group_in_airport
      @selected_group
    end

    def refresh_all
      # Live flight tracking (OAG) was removed to cut cost. Flight details are
      # entered manually, so there is nothing to refresh from an external source.
      redirect_to admin_event_airport_mode_path(current_event, tab: params[:tab]),
        alert: "Live flight tracking is disabled. Flight details are entered manually."
    end

    def refresh_status
      cache_key = "airport_mode/#{current_event.id}/refresh_status"
      status = Rails.cache.read(cache_key) || { status: "idle" }
      render json: status
    end

    def dismiss_pickup
      travel = Travel.find(params[:travel_id])
      travel.dismiss_pickup!
      clear_flights_cache

      redirect_to admin_event_airport_mode_path(current_event),
        notice: "Pickup dismissed for #{travel.participant.display_name}."
    end

    def flights_json
      load_flights_data
      all_legs = @inbound_journeys.flat_map { |j| j[:legs].map { |l| l.merge(type: "inbound") } } +
                 @outbound_journeys.flat_map { |j| j[:legs].map { |l| l.merge(type: "outbound") } }

      render json: {
        flights: all_legs,
        event_location: current_event.venue_coordinates
      }
    end

    private

    def require_travel_enabled
      return if current_event.travel_enabled?

      redirect_to admin_event_dashboard_path(current_event.slug), alert: "Travel is disabled for this event."
    end

    def far_future
      Time.current + 100.years
    end

    def load_flights_data
      cache_key = "airport_mode/#{current_event.id}/journeys/v3"

      cached_data = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
        {
          inbound: collect_journeys(:inbound),
          outbound: collect_journeys(:outbound)
        }
      end

      @inbound_journeys = cached_data[:inbound]
      @outbound_journeys = cached_data[:outbound]
    end

    def clear_flights_cache
      Rails.cache.delete("airport_mode/#{current_event.id}/journeys/v3")
    end

    def collect_journeys(direction)
      participant_events = current_event.participant_events
        .where(status: :complete)
        .includes(participant: :headshot_attachment)
        .includes(:groups, scans: :scan_context, travel_inbound: { travel_legs: :picked_up_by }, travel_outbound: { travel_legs: :picked_up_by })

      journeys = []

      participant_events.each do |pe|
        travel = direction == :inbound ? pe.travel_inbound : pe.travel_outbound
        next unless travel&.plane?
        next if travel.travel_legs.empty?

        legs_data = travel.travel_legs.map { |leg| build_leg_data(leg, pe, direction) }

        airport_or_check_in_scans = pe.scans.select { |s| s.scan_context&.is_airport || s.scan_context&.checks_in }
        scanned_in = airport_or_check_in_scans.any?
        pickup_dismissed = travel.pickup_dismissed?

        primary_leg = direction == :inbound ? legs_data.last : legs_data.first

        # For inbound, "picked_up" means scanned in OR pickup dismissed (organizer marked as handled)
        primary_status = primary_leg[:status]
        if direction == :inbound && (scanned_in || pickup_dismissed) && primary_status == :landed
          primary_status = :picked_up
        end

        journeys << {
          id: travel.id,
          participant_id: pe.participant.id,
          participant_event_id: pe.id,
          participant_name: pe.participant.display_name,
          participant_preferred_name: pe.participant.preferred_name,
          participant_has_headshot: pe.participant.headshot.attached?,
          direction: direction,
          legs: legs_data,
          final_leg: legs_data.last,
          primary_leg: primary_leg,
          leg_count: legs_data.size,
          scanned_in: scanned_in,
          scanned_at: airport_or_check_in_scans.map(&:scanned_at).compact.max,
          # Only admin-verified UMs get the badge — self-declared alone isn't enough.
          is_unaccompanied_minor: travel.is_unaccompanied_minor? && pe.um_approved?,
          travel_mode: travel.mode,
          pickup_dismissed: pickup_dismissed,
          status: primary_status,
          status_label: status_label(primary_status),
          status_color: status_color(primary_status),
          is_delayed: primary_leg[:is_delayed] && %i[scheduled in_flight].include?(primary_status),
          delay_minutes: primary_leg[:delay_minutes],
          primary_time_at: primary_leg[direction == :inbound ? :eta_at : :etd_at],
          primary_time_iso: primary_leg[direction == :inbound ? :eta_iso : :etd_iso],
          primary_scheduled_iso: primary_leg[direction == :inbound ? :scheduled_arrival_iso : :scheduled_departure_iso],
          primary_airport_iata: direction == :inbound ? primary_leg[:arrival_airport] : primary_leg[:departure_airport],
          primary_terminal: direction == :inbound ? primary_leg[:arrival_terminal] : primary_leg[:departure_terminal],
          primary_gate: direction == :inbound ? primary_leg[:arrival_gate] : primary_leg[:departure_gate],
          primary_airport_tz: direction == :inbound ? primary_leg[:arrival_tz] : primary_leg[:departure_tz],
          arriving_now: direction == :inbound &&
                         primary_leg[:eta_at].present? &&
                         primary_leg[:eta_at] <= Time.current + ARRIVING_NOW_WINDOW &&
                         on_final_leg_in_progress?(legs_data),
          groups: current_event.groups_enabled? ? pe.groups.map { |g| { id: g.id, name: g.name, color: g.normalized_color } } : []
        }
      end

      journeys.sort_by do |j|
        j[:primary_time_at] || far_future
      end
    end

    def on_final_leg_in_progress?(legs_data)
      return true if legs_data.size == 1
      final = legs_data.last
      return true if %i[in_flight landed picked_up].include?(final[:status])
      legs_data[0..-2].all? { |l| %i[landed picked_up].include?(l[:status]) }
    end

    def build_leg_data(leg, pe, direction)
      eta = FlightEta.for(leg)
      tracking = leg.live_tracking_data || {}

      etd_at = parse_iso(tracking[:actual_departure]) || parse_iso(tracking[:scheduled_departure]) || leg.live_departure_time || leg.departure_time
      scheduled_dep_at = parse_iso(tracking[:scheduled_departure]) || leg.departure_time

      data = {
        id: leg.id,
        participant_name: pe.participant.display_name,
        participant_event_id: pe.id,
        flight_code: leg.flight_code,
        direction: direction,
        departure_airport: leg.departure_airport,
        arrival_airport: leg.arrival_airport,

        # Canonical times via FlightEta
        eta_at: eta.eta,
        eta_iso: eta.eta&.iso8601,
        eta_source: eta.eta_source,
        scheduled_arrival_at: eta.scheduled,
        scheduled_arrival_iso: eta.scheduled&.iso8601,
        delay_minutes: eta.delay_minutes,
        is_delayed: eta.is_delayed,
        status: eta.status,                # :scheduled, :in_flight, :landed, :picked_up, :cancelled, :diverted
        status_label: status_label(eta.status),
        status_color: status_color(eta.status),
        raw_status: eta.raw_status,

        # Departure side
        etd_at: etd_at,
        etd_iso: etd_at&.iso8601,
        scheduled_departure_iso: scheduled_dep_at&.iso8601,

        # Legacy keys kept for the map JSON consumer
        departure_time: leg.departure_time&.iso8601,
        arrival_time: leg.arrival_time&.iso8601,

        progress: tracking[:progress],
        departure_coordinates: tracking[:departure_coordinates],
        arrival_coordinates: tracking[:arrival_coordinates],
        current_coordinates: tracking[:current_coordinates],
        last_tracked_at: leg.last_tracked_at,
        oag_schedule_instance_key: leg.oag_schedule_instance_key,
        departure_tz: FlightTrackingService.airport_timezone(leg.departure_airport),
        arrival_tz: FlightTrackingService.airport_timezone(leg.arrival_airport),
        departure_gate: tracking[:gate],
        departure_terminal: tracking[:terminal],
        arrival_gate: tracking[:arrival_gate],
        arrival_terminal: tracking[:arrival_terminal],
        aircraft_type: tracking[:aircraft_type],
        registration: tracking[:registration],
        picked_up_at: leg.airport_picked_up_at,
        picked_up_by: leg.picked_up_by&.name || leg.picked_up_by&.email
      }
      data[:report_url] = helpers.flight_report_url(
        leg: data,
        event: current_event,
        user: current_user,
        source_url: request.original_url,
        participant_name: pe.participant.display_name
      )
      data
    end

    def parse_iso(value)
      return nil if value.blank?
      case value
      when Time, ActiveSupport::TimeWithZone, DateTime then value.to_time
      when String then (Time.parse(value) rescue nil)
      end
    end

    def status_label(status)
      {
        scheduled: "Scheduled",
        in_flight: "In flight",
        landed: "Landed",
        picked_up: "Picked up",
        cancelled: "Cancelled",
        diverted: "Diverted"
      }[status] || status.to_s
    end

    def status_color(status)
      {
        scheduled: "gray",
        in_flight: "blue",
        landed: "amber",
        picked_up: "green",
        cancelled: "red",
        diverted: "orange"
      }[status] || "gray"
    end

    def build_summary_counts(journeys, direction)
      now = Time.current
      counts = Hash.new(0)
      counts[:total] = journeys.size

      journeys.each do |j|
        case j[:status]
        when :cancelled then counts[:cancelled] += 1
        when :diverted  then counts[:diverted] += 1
        when :landed    then counts[:landed_waiting] += 1
        when :picked_up then counts[:picked_up] += 1
        when :in_flight then counts[:in_flight] += 1
        when :scheduled then counts[:scheduled] += 1
        end
        counts[:delayed] += 1 if j[:is_delayed]
        counts[:ums] += 1 if j[:is_unaccompanied_minor]
        counts[:arriving_now] += 1 if j[:arriving_now] && !%i[picked_up].include?(j[:status])
      end

      counts[:alerts] = counts[:cancelled] + counts[:diverted] + counts[:delayed]
      counts
    end
  end
end
