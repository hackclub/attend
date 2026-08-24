module Admin
  class AirportModeController < BaseController
    before_action :require_event_selected
    before_action :require_travel_enabled

    def show
      redirect_to admin_event_travel_path(current_event, request.query_parameters)
    end

    private

    def require_travel_enabled
      return if current_event.travel_enabled?

      redirect_to admin_event_dashboard_path(current_event.slug), alert: "Travel is disabled for this event."
    end
  end
end
