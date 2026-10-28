module Api
  module V1
    # Who can read an event's stays and change their rosters: an event or
    # series API key for that event (a shop selling the night), or a person or
    # global token allowed to run rooming for it. A scoped global token needs
    # rooming:write.
    module RoomingStayAccess
      extend ActiveSupport::Concern

      included do
        include Pundit::Authorization

        rescue_from Pundit::NotAuthorizedError do
          render json: { error: "Forbidden" }, status: :forbidden
        end

        requires_scope "rooming:write"

        before_action :set_event
      end

      private

      def set_event
        @event = Event.find_by(id: params[:event_id]) || Event.find_by!(slug: params[:event_id])
        Current.event = @event

        if api_key_request?
          require_api_key_event_scope!(@event)
        else
          authorize @event, :manage_rooming?
        end
      end

      def stay_json(stay)
        {
          id: stay.id,
          name: stay.name,
          kind: stay.kind,
          enrollment: stay.enrollment,
          starts_on: stay.starts_on,
          ends_on: stay.ends_on,
          eligibility_options: stay.eligibility_options.map { |option| option_json(option) }
        }
      end

      def option_json(option)
        { id: option.id, label: option.label, price_cents: option.price_cents }
      end
    end
  end
end
