module Api
  module V1
    # Read-only view of an event series.
    #
    # The point of the Series API is that a series organizer holds one
    # credential for a whole series: `GET /series/current` tells a client which
    # series its key belongs to, and everything else hangs off
    # `/series/:series_id/events`.
    class SeriesController < BaseController
      include Pundit::Authorization
      include SeriesScoped

      rescue_from Pundit::NotAuthorizedError do
        render json: { error: "Forbidden" }, status: :forbidden
      end

      skip_before_action :set_series, only: [ :index ]

      def index
        render json: { series: visible_series.map { |series| series_json(series) } }
      end

      def show
        render json: { series: series_json(@series, detailed: true) }
      end

      private

      # A series key sees exactly one series — itself — so index doubles as
      # "who am I?" for a client that only has the key.
      def visible_series
        if current_series_from_api_key
          EventSeries.where(id: current_series_from_api_key.id)
        elsif current_event_from_api_key
          EventSeries.none
        else
          policy_scope(EventSeries)
        end.order(:name)
      end

      def series_json(series, detailed: false)
        payload = {
          id: series.id,
          slug: series.slug,
          name: series.name,
          description: series.description,
          contact_email: series.contact_email,
          event_count: series.events.size,
          created_at: series.created_at.iso8601,
          updated_at: series.updated_at.iso8601
        }
        return payload unless detailed

        payload.merge(
          events: series.events.order(:starts_at).map do |event|
            { id: event.id, slug: event.slug, name: event.name, starts_at: event.starts_at&.iso8601 }
          end
        )
      end
    end
  end
end
