module Admin
  class EventSeriesController < BaseController
    before_action :set_series, only: [ :show, :edit, :update ]

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
