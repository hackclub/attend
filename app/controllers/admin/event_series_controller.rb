module Admin
  class EventSeriesController < BaseController
    before_action :set_series, only: [ :show, :edit, :update ]

    def index
      authorize EventSeries, :index?
      @series_list = policy_scope(EventSeries).order(:name)
    end

    def show
      authorize @series
      @events = @series.events
        .includes(logo_attachment: :blob, event_series: { logo_attachment: :blob })
        .order(starts_at: :desc)
      @event_participant_counts = ParticipantEvent.where(event: @events).group(:event_id).count
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
