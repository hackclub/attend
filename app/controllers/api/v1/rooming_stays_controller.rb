module Api
  module V1
    # An event's stays (during, before, after the event) and the eligibility
    # options on each, so an integration can find the stay and option ids it
    # needs for the roster endpoints.
    class RoomingStaysController < BaseController
      include RoomingStayAccess

      def index
        stays = @event.rooming_contexts.ordered.includes(:eligibility_options)

        render json: { stays: stays.map { |stay| stay_json(stay) } }
      end
    end
  end
end
