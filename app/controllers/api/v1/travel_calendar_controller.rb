module Api
  module V1
    class TravelCalendarController < BaseController
      before_action :set_event
      before_action :authorize_event

      def show
        entries = TravelCalendar::JourneyCache.fetch(@event)

        render json: {
          eventTimezone: event_timezone,
          dates: entries.filter_map { |entry| entry[:agenda_date]&.iso8601 }.uniq,
          entries: entries.map { |entry| serialize_entry(entry) },
          counts: serialize_counts(entries)
        }
      end

      private

      def set_event
        @event = Event.find(params[:event_id])
      end

      def authorize_event
        require_event_access!(@event) if current_user
      end

      def event_timezone
        @event.timezone_identifier || @event.event_time_zone.tzinfo.name
      end

      def serialize_entry(entry)
        {
          id: entry[:id],
          participantId: entry[:participant_id],
          participantEventId: entry[:participant_event_id],
          participantName: entry[:participant_name],
          participantPreferredName: entry[:participant_preferred_name],
          direction: entry[:direction],
          mode: entry[:mode],
          primaryTimeAt: entry[:primary_time_at]&.in_time_zone(@event.event_time_zone)&.iso8601,
          agendaDate: entry[:agenda_date]&.iso8601,
          route: entry[:route],
          reference: entry[:reference],
          details: entry[:details],
          pickupState: entry[:pickup_state]&.to_s,
          isUnaccompaniedMinor: entry[:is_unaccompanied_minor],
          groups: entry[:groups]
        }
      end

      def serialize_counts(entries)
        {
          total: entries.size,
          inbound: entries.count { |entry| entry[:direction] == "inbound" },
          outbound: entries.count { |entry| entry[:direction] == "outbound" },
          scheduled: entries.count { |entry| entry[:agenda_date].present? },
          unscheduled: entries.count { |entry| entry[:agenda_date].nil? },
          awaitingPickup: entries.count { |entry| entry[:pickup_state] == :awaiting_pickup },
          collected: entries.count { |entry| entry[:pickup_state] == :collected },
          checkedIn: entries.count { |entry| entry[:pickup_state] == :checked_in },
          pickupNotNeeded: entries.count { |entry| entry[:pickup_state] == :pickup_not_needed }
        }
      end
    end
  end
end
