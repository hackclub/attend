module Api
  module V1
    class AirportModeController < BaseController
      before_action :set_event
      before_action :authorize_event

      ARRIVING_NOW_WINDOW = 30.minutes

      def show
        load_flights_data

        tab = params[:tab].presence_in(%w[inbound outbound]) || "inbound"
        journeys = tab == "outbound" ? @outbound_journeys : @inbound_journeys

        inbound_counts = build_counts(@inbound_journeys, :inbound)
        outbound_counts = build_counts(@outbound_journeys, :outbound)

        airports = journeys.map { |j| j[:primary_airport_iata] }.compact.uniq.sort
        terminals = journeys.map { |j| j[:primary_terminal] }.compact.uniq.sort

        last_refreshed_at = (@inbound_journeys + @outbound_journeys)
          .flat_map { |j| j[:legs].map { |l| l[:last_tracked_at] } }
          .compact.max

        render json: {
          tab: tab,
          last_refreshed_at: last_refreshed_at&.iso8601,
          event_timezone: @event.timezone_identifier,
          counts: {
            inbound: inbound_counts,
            outbound: outbound_counts
          },
          airports: airports,
          terminals: terminals,
          journeys: journeys.map { |j| serialize_journey(j) }
        }
      end

      private

      def far_future
        Time.current + 100.years
      end

      def set_event
        @event = Event.find(params[:event_id])
      end

      def authorize_event
        require_event_access!(@event) if current_user
      end

      def load_flights_data
        cache_key = "airport_mode/#{@event.id}/journeys/v3"

        cached_data = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
          {
            inbound: collect_journeys(:inbound),
            outbound: collect_journeys(:outbound)
          }
        end

        @inbound_journeys = cached_data[:inbound]
        @outbound_journeys = cached_data[:outbound]
      end

      def collect_journeys(direction)
        participant_events = @event.participant_events
          .where(status: :complete)
          .includes(participant: { headshot_attachment: :blob })
          .includes(scans: :scan_context, travel_inbound: { travel_legs: :picked_up_by }, travel_outbound: { travel_legs: :picked_up_by })

        journeys = []

        participant_events.each do |pe|
          travel = direction == :inbound ? pe.travel_inbound : pe.travel_outbound
          next unless travel&.plane?
          next if travel.travel_legs.empty?

          legs_data = travel.travel_legs.map { |leg| build_leg_data(leg, pe, direction) }

          airport_or_check_in_scans = pe.scans.select { |s| s.scan_context&.is_airport || s.scan_context&.checks_in }
          scanned_in = airport_or_check_in_scans.any?
          pickup_dismissed = travel.respond_to?(:pickup_dismissed?) && travel.pickup_dismissed?

          primary_leg = direction == :inbound ? legs_data.last : legs_data.first
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
            participant_has_headshot: pe.participant.headshot_displayable?,
            participant_headshot_url: headshot_url_for(pe.participant),
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
                           on_final_leg_in_progress?(legs_data)
          }
        end

        journeys.sort_by { |j| j[:primary_time_at] || far_future }
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

        etd_at = parse_iso(tracking[:actual_departure]) || parse_iso(tracking[:scheduled_departure]) || leg.try(:live_departure_time) || leg.departure_time
        scheduled_dep_at = parse_iso(tracking[:scheduled_departure]) || leg.departure_time

        {
          id: leg.id,
          participant_event_id: pe.id,
          flight_code: leg.flight_code,
          direction: direction,
          departure_airport: leg.departure_airport,
          arrival_airport: leg.arrival_airport,
          eta_at: eta.eta,
          eta_iso: eta.eta&.iso8601,
          eta_source: eta.eta_source,
          scheduled_arrival_at: eta.scheduled,
          scheduled_arrival_iso: eta.scheduled&.iso8601,
          delay_minutes: eta.delay_minutes,
          is_delayed: eta.is_delayed,
          status: eta.status,
          status_label: status_label(eta.status),
          status_color: status_color(eta.status),
          raw_status: eta.raw_status,
          etd_at: etd_at,
          etd_iso: etd_at&.iso8601,
          scheduled_departure_iso: scheduled_dep_at&.iso8601,
          departure_time: leg.departure_time&.iso8601,
          arrival_time: leg.arrival_time&.iso8601,
          progress: tracking[:progress],
          last_tracked_at: leg.last_tracked_at,
          departure_tz: FlightTrackingService.airport_timezone(leg.departure_airport),
          arrival_tz: FlightTrackingService.airport_timezone(leg.arrival_airport),
          departure_gate: tracking[:gate],
          departure_terminal: tracking[:terminal],
          arrival_gate: tracking[:arrival_gate],
          arrival_terminal: tracking[:arrival_terminal],
          departure_coordinates: tracking[:departure_coordinates],
          arrival_coordinates: tracking[:arrival_coordinates],
          current_coordinates: tracking[:current_coordinates]
        }
      end

      def serialize_journey(j)
        primary_leg = j[:primary_leg]
        {
          id: j[:id].to_s,
          participantId: j[:participant_id].to_s,
          participantEventId: j[:participant_event_id].to_s,
          participantName: j[:participant_preferred_name].presence || j[:participant_name],
          participantFullName: j[:participant_name],
          participantHasHeadshot: j[:participant_has_headshot],
          participantHeadshotUrl: j[:participant_headshot_url],
          direction: j[:direction].to_s,
          status: j[:status].to_s,
          statusLabel: j[:status_label],
          statusColor: j[:status_color],
          isDelayed: j[:is_delayed] ? true : false,
          delayMinutes: j[:delay_minutes].to_i,
          isUnaccompaniedMinor: j[:is_unaccompanied_minor] ? true : false,
          arrivingNow: j[:arriving_now] ? true : false,
          isAlert: alert_for_journey?(j),
          scannedIn: j[:scanned_in] ? true : false,
          scannedAt: j[:scanned_at]&.iso8601,
          legCount: j[:leg_count],
          primaryAirport: j[:primary_airport_iata],
          primaryTerminal: j[:primary_terminal],
          primaryGate: j[:primary_gate],
          primaryTimezone: j[:primary_airport_tz],
          primaryTimeIso: j[:primary_time_iso],
          primaryScheduledIso: j[:primary_scheduled_iso],
          progress: primary_leg[:progress],
          lastTrackedAt: primary_leg[:last_tracked_at]&.iso8601,
          legs: j[:legs].map { |l| serialize_leg(l) }
        }
      end

      def alert_for_journey?(j)
        return true if %i[cancelled diverted].include?(j[:status])
        return true if j[:is_delayed]
        false
      end

      def serialize_leg(leg)
        {
          id: leg[:id].to_s,
          flightCode: leg[:flight_code],
          origin: leg[:departure_airport],
          destination: leg[:arrival_airport],
          departureTime: leg[:etd_iso] || leg[:departure_time],
          arrivalTime: leg[:eta_iso] || leg[:arrival_time],
          status: leg[:status].to_s,
          statusLabel: leg[:status_label],
          statusColor: leg[:status_color],
          departureTerminal: leg[:departure_terminal],
          departureGate: leg[:departure_gate],
          arrivalTerminal: leg[:arrival_terminal],
          arrivalGate: leg[:arrival_gate],
          departureTimezone: leg[:departure_tz],
          arrivalTimezone: leg[:arrival_tz],
          scheduledDepartureIso: leg[:scheduled_departure_iso],
          scheduledArrivalIso: leg[:scheduled_arrival_iso],
          progress: leg[:progress],
          departureCoordinates: leg[:departure_coordinates],
          arrivalCoordinates: leg[:arrival_coordinates],
          currentCoordinates: leg[:current_coordinates],
          delayMinutes: leg[:delay_minutes].to_i,
          isDelayed: leg[:is_delayed] ? true : false
        }
      end

      def build_counts(journeys, _direction)
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
          counts[:arriving_now] += 1 if j[:arriving_now] && j[:status] != :picked_up
        end
        counts[:alerts] = counts[:cancelled] + counts[:diverted] + counts[:delayed]
        counts.transform_keys(&:to_s)
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

      def headshot_url_for(participant)
        return nil unless participant.headshot.attached?

        host = request.host_with_port
        protocol = request.protocol
        path = Rails.application.routes.url_helpers.rails_storage_proxy_path(participant.headshot, only_path: true)
        "#{protocol}#{host}#{path}"
      rescue StandardError => e
        Rails.logger.error("Failed to generate headshot URL: #{e.message}")
        nil
      end
    end
  end
end
