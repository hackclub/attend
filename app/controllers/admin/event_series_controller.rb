module Admin
  class EventSeriesController < BaseController
    before_action :set_series, only: [ :show, :edit, :update, :send_held_invitations ]

    def index
      authorize EventSeries, :index?
      @series_list = policy_scope(EventSeries).order(:name)
    end

    def show
      authorize @series

      # scan_contexts and custom_documents are preloaded because the dashboard's
      # single pass over participants asks every event whether it records
      # check-ins and which documents apply — per event, not per participant.
      @events = SeriesDashboard.order_events(
        @series.events
          .includes(:scan_contexts, :custom_documents, logo_attachment: :blob, event_series: { logo_attachment: :blob })
          .to_a
      )

      @dashboard = SeriesDashboard.new(@series, events: @events, user: current_user)
      @event_rows = @dashboard.event_rows
    end

    # The series HQ button: every event that is holding onboarding
    # invitations, or has some recorded but unsent, sends them now and stops
    # holding. Events with nothing held are left alone.
    def send_held_invitations
      authorize @series

      events = @series.events.select { |event| event.onboarding_invites_held? || event.invitations.held.exists? }
      count = Invitation.where(event_id: events.map(&:id)).held.count
      events.each(&:release_onboarding_invites!)
      @record = @series

      if events.empty?
        redirect_to admin_series_path(@series), notice: "No held invitations to send."
      else
        redirect_to admin_series_path(@series),
          notice: "Sending #{helpers.pluralize(count, 'held invitation')} across #{helpers.pluralize(events.size, 'event')}. New participants on those events will be emailed as they're added."
      end
    end

    def new
      @series = EventSeries.new
      authorize @series
    end

    def create
      @series = EventSeries.new(series_params)
      authorize @series

      if @series.save
        redirect_to admin_series_path(@series), notice: "#{@series.name} created! Add members so they can start making events."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @series
    end

    def update
      authorize @series

      if @series.update(series_params)
        redirect_to admin_series_path(@series), notice: "Series updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_series
      @series = EventSeries.find_by!(slug: params[:slug])
    end

    def series_params
      params.require(:event_series).permit(:name, :slug, :description, :contact_email, :logo, :banner)
    end
  end
end
