module Api
  module V1
    class ScanContextsController < BaseController
      before_action :set_event
      before_action :require_event_access

      def index
        contexts = @event.scan_contexts

        render json: {
          scan_contexts: contexts.map { |c| context_json(c) }
        }
      end

      private

      def set_event
        @event = Event.find(params[:event_id])
      end

      def require_event_access
        require_event_access!(@event)
      end

      def context_json(context)
        {
          id: context.id,
          name: context.name,
          checks_in: context.checks_in,
          is_travel_pickup: context.is_travel_pickup,
          is_airport: context.is_travel_pickup,
          position: context.position,
          starts_at: context.starts_at&.in_time_zone(@event.event_time_zone)&.iso8601,
          ends_at: context.ends_at&.in_time_zone(@event.event_time_zone)&.iso8601
        }
      end
    end
  end
end
