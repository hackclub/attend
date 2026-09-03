module Api
  module V1
    # Resolves the `:series_id` / `:id` path segment for the Series API and
    # decides who may touch it.
    #
    # Two credentials reach these endpoints:
    #
    # * a **series API key**, which carries its series with it. It may only
    #   ever address that one series, so the path segment is checked against
    #   the token rather than against a policy — and may be given as the
    #   literal `current` so a client never has to hardcode an id.
    # * a **user token** (mobile or global), which is authorized through
    #   EventSeriesPolicy exactly as the web is.
    module SeriesScoped
      extend ActiveSupport::Concern

      # Stand-in for "whichever series this key belongs to".
      CURRENT_SERIES_KEYWORD = "current".freeze

      included do
        before_action :set_series
      end

      private

      def set_series
        identifier = params[:series_id] || params[:id]

        if identifier == CURRENT_SERIES_KEYWORD
          unless current_series_from_api_key
            render json: { error: "`current` is only meaningful for a series API key" },
                   status: :bad_request
            return
          end

          @series = current_series_from_api_key
        else
          @series = find_series(identifier)
          return render json: { error: "Series not found" }, status: :not_found if @series.nil?
        end

        authorize_series
      end

      # Slugs are what organizers actually have to hand; ids keep the endpoint
      # usable from stored references. Slugs can't collide with UUIDs, so
      # trying the id first is unambiguous (a non-UUID string casts to NULL
      # and simply misses).
      def find_series(identifier)
        return nil if identifier.blank?

        EventSeries.find_by(id: identifier) || EventSeries.find_by(slug: identifier)
      end

      def authorize_series
        if current_series_from_api_key
          unless current_series_from_api_key.id == @series.id
            render json: { error: "API key is not valid for this series" }, status: :forbidden
          end
        elsif current_event_from_api_key
          # An event key is scoped to a single event and has no standing over
          # the series that event happens to sit in.
          render json: { error: "An event API key cannot be used on the Series API" },
                 status: :forbidden
        else
          authorize @series, :show?
        end
      end
    end
  end
end
