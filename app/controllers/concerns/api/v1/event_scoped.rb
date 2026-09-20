module Api
  module V1
    # Resolves the `:event_id` path segment for the event-scoped API and
    # decides who may touch that event.
    #
    # Every credential kind reaches these endpoints, so the check has two
    # halves: an API key is measured against the event it was issued for (an
    # event key: that one event; a series key: any event in its series), and a
    # user token is put through Pundit exactly as the web is. Controllers say
    # which policy question to ask by overriding `authorize_event_access!`.
    module EventScoped
      extend ActiveSupport::Concern

      included do
        before_action :set_event
      end

      private

      def set_event
        @event = find_event(params[:event_id])
        return render json: { error: "Event not found" }, status: :not_found if @event.nil?

        Current.event = @event

        if api_key_request?
          require_api_key_event_scope!(@event)
        else
          authorize_event_access!
        end
      end

      # Slugs are what organizers have to hand; ids keep the endpoint usable
      # from stored references. A non-UUID string casts to NULL against the id
      # column and simply misses, so trying the id first is unambiguous.
      def find_event(identifier)
        return nil if identifier.blank?

        Event.find_by(id: identifier) || Event.find_by(slug: identifier)
      end

      # Overridden per controller. `update?` is the same question the web asks
      # before letting someone edit an event at all.
      def authorize_event_access!
        authorize @event, :update?
      end
    end
  end
end
