module Admin
  class TravelCalendarController < BaseController
    rescue_from ActiveRecord::RecordNotFound, with: :render_record_not_found

    before_action :require_event_selected
    before_action :require_travel_enabled

    def show
      @journeys = TravelCalendar::JourneyCache.fetch(current_event)
      @entries = @journeys
      @journeys_by_date = @journeys.select { |journey| journey[:agenda_date].present? }.group_by { |journey| journey[:agenda_date] }
      @unscheduled_journeys = @journeys.select { |journey| journey[:agenda_date].nil? }
      @summary_counts = summary_counts(@journeys)
      @participants_by_id = Participant
        .where(id: @journeys.filter_map { |journey| journey[:participant_id] }.uniq)
        .with_attached_headshot
        .index_by(&:id)
      @groups = current_event.groups_enabled? ? current_event.groups.ordered : Group.none
      @directions = Travel.directions.keys
      @modes = Travel.modes.keys
      @pickup_states = %w[awaiting_pickup collected checked_in pickup_not_needed]
      @filter_choices = {
        directions: @directions,
        modes: @modes,
        pickup_states: @pickup_states,
        groups: @groups
      }
    end

    def dismiss_pickup
      travel = Travel.joins(:participant_event)
        .where(participant_events: { event_id: current_event.id })
        .inbound
        .find(params[:travel_id])
      travel.dismiss_pickup!
      TravelCalendar::JourneyCache.clear(current_event)

      redirect_to admin_event_travel_path(current_event), notice: "Pickup marked as not needed."
    end

    private

    def render_record_not_found
      head :not_found
    end

    def require_travel_enabled
      return if current_event.travel_enabled?

      redirect_to admin_event_dashboard_path(current_event.slug), alert: "Travel is disabled for this event."
    end

    def summary_counts(journeys)
      {
        total: journeys.size,
        inbound: journeys.count { |journey| journey[:direction] == "inbound" },
        outbound: journeys.count { |journey| journey[:direction] == "outbound" },
        awaiting_pickup: journeys.count { |journey| journey[:pickup_state] == :awaiting_pickup },
        collected: journeys.count { |journey| journey[:pickup_state] == :collected },
        checked_in: journeys.count { |journey| journey[:pickup_state] == :checked_in },
        pickup_not_needed: journeys.count { |journey| journey[:pickup_state] == :pickup_not_needed },
        unaccompanied_minors: journeys.count { |journey| journey[:is_unaccompanied_minor] }
      }
    end
  end
end
