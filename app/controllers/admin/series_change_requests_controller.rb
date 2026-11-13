module Admin
  # Registration change requests across every event in a series. Series
  # members act as event admins on each of the series' events, so they see
  # every audience; reviewing a request still happens on its event's page.
  class SeriesChangeRequestsController < BaseController
    global_page
    before_action :set_series

    STATUS_FILTERS = %w[pending follow_up_needed approved dismissed all].freeze

    def index
      authorize @series, :view_change_requests?

      @events = @series.events.order(starts_at: :desc).to_a
      series_requests = RegistrationChangeRequest
        .joins(:participant_event)
        .where(participant_events: { event_id: @events.map(&:id) })

      @status_counts = series_requests.group(:status).count
      @status_filter = STATUS_FILTERS.include?(params[:status]) ? params[:status] : "pending"
      @event_filter = @events.find { |event| event.slug == params[:event] }

      scope = series_requests
      scope = scope.where(status: @status_filter) unless @status_filter == "all"
      scope = scope.where(participant_events: { event_id: @event_filter.id }) if @event_filter

      @change_requests = scope
        .includes(participant_event: [ :participant, :event ])
        .pending_first
    end

    private

    def set_series
      @series = EventSeries.find_by!(slug: params[:series_slug])
    end
  end
end
