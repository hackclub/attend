module Admin
  class AirportModeController < BaseController
    before_action :require_event_selected
    before_action :require_travel_enabled

    def show
      query = request.query_parameters.to_h
      legacy_direction = query.delete("tab")
      legacy_group = query.delete("group_id")
      query["direction"] = legacy_direction if !query.key?("direction") && legacy_direction.present?
      query["group"] = legacy_group if !query.key?("group") && legacy_group.present?

      redirect_to admin_event_travel_path(current_event, query)
    end

    private

    def require_travel_enabled
      return if current_event.travel_enabled?

      redirect_to admin_event_dashboard_path(current_event.slug), alert: "Travel is disabled for this event."
    end
  end
end
