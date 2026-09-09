module Admin
  # Series-level view of the vote.hackclub.com integration.
  #
  # A vote event is per Attend event, but deciding which of a series' events
  # get a voting gallery is a decision about the series — so this lists them
  # all with a button each, instead of making somebody walk every satellite's
  # own integrations page.
  class SeriesIntegrationsController < BaseController
    skip_before_action :set_current_event_from_session

    before_action :set_series
    before_action :require_series_owner_access

    def show
      @vote_client = Vote::Client.new
      @events = @series.events
        .includes(logo_attachment: :blob, banner_attachment: :blob)
        .order(Arel.sql("starts_at ASC NULLS LAST"))
    end

    def create_vote_event
      event = @series.events.find_by(slug: params[:event_id]) ||
        @series.events.find_by(id: params[:event_id])
      return redirect_to admin_series_integrations_path(@series), alert: "That event is not in this series." if event.nil?

      authorize event, :update?

      # Same reason as the event's own page: without a current event the audit
      # row lands with a null event_id and hides from non-global admins.
      set_current_event(event)

      result = Vote::EventLinker.new(event).call
      redirect_to admin_series_integrations_path(@series),
        (result.linked? ? :notice : :alert) => "#{event.name}: #{result.message}"
    end

    private

    def set_series
      @series = EventSeries.find_by!(slug: params[:series_slug])
    end

    def require_series_owner_access
      return if policy(@series).manage_integrations?

      redirect_to admin_series_path(@series), alert: "Only series owners can manage integrations."
    end
  end
end
