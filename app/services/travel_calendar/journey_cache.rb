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
        clear_event_ids([ event.id ])
      end

      def clear_event_ids(event_ids)
        Array(event_ids).compact_blank.uniq.each do |event_id|
          Rails.cache.delete(cache_key_for(event_id))
        end
      end

      private

      def cache_key(event)
        cache_key_for(event.id)
      end

      def cache_key_for(event_id)
        "travel_calendar/#{event_id}/journeys/v1"
      end
    end
  end
end
