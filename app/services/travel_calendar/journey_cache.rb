module TravelCalendar
  class JourneyCache
    EXPIRY = 5.minutes

    class << self
      # `include_addresses: false` blanks the pickup address a car journey
      # carries as its route, for the PII-restricted roles (see
      # EventRoleAssignment::PII_RESTRICTED_ROLES). Redaction happens on the way
      # out rather than in the builder so the cache stays a single entry shared
      # by every role.
      def fetch(event, include_addresses: true)
        journeys = Rails.cache.fetch(cache_key(event), expires_in: EXPIRY) do
          JourneyBuilder.new(event: event).call
        end

        include_addresses ? journeys : redact_pickup_addresses(journeys)
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

      # New hashes, not edits to the cached ones: the development memory_store
      # hands back the very objects it is holding, so mutating in place would
      # strip the address for every other reader too.
      def redact_pickup_addresses(journeys)
        journeys.map do |journey|
          next journey unless journey[:mode] == "car" && journey[:route].present?

          journey.merge(route: "Address hidden")
        end
      end

      def cache_key(event)
        cache_key_for(event.id)
      end

      def cache_key_for(event_id)
        "travel_calendar/#{event_id}/journeys/v1"
      end
    end
  end
end
