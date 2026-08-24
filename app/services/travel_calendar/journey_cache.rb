module TravelCalendar
  class JourneyCache
    EXPIRY = 5.minutes

    class << self
      def fetch(event)
        Rails.cache.fetch(cache_key(event), expires_in: EXPIRY) do
          JourneyBuilder.new(event: event).call
        end
      end

      def clear(event)
        Rails.cache.delete(cache_key(event))
      end

      private

      def cache_key(event)
        "travel_calendar/#{event.id}/journeys/v1"
      end
    end
  end
end
