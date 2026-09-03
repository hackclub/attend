module Api
  module V1
    # One shape for an event across the Series API, so a POST response, a PATCH
    # response and a GET of the same event never drift apart.
    module EventSerialization
      extend ActiveSupport::Concern

      private

      # `summary: true` drops the module flags and the setup detail — enough to
      # list a series' events without paying for fields a list view ignores.
      def series_event_json(event, summary: false)
        payload = {
          id: event.id,
          slug: event.slug,
          name: event.name,
          series: {
            id: event.event_series_id,
            slug: event.event_series&.slug,
            name: event.event_series&.name
          },
          support_email: event.support_email,
          timezone: event.timezone_identifier,
          starts_at: event.starts_at&.iso8601,
          ends_at: event.ends_at&.iso8601,
          registration_open_at: event.registration_open_at&.iso8601,
          registration_close_at: event.registration_close_at&.iso8601,
          venue_name: event.venue_name,
          location_city: event.location_city,
          location_country: event.location_country,
          location_address: event.location_address,
          location_latitude: event.location_latitude&.to_f,
          location_longitude: event.location_longitude&.to_f,
          setup_complete: event.setup_complete?,
          created_at: event.created_at.iso8601,
          updated_at: event.updated_at.iso8601
        }
        return payload if summary

        payload.merge(
          # Read through the `?` predicates: the flags live in a jsonb store
          # and hold whatever the web form last wrote ("1", "true", true), so
          # only the predicates give a client a real boolean.
          modules: {
            freedom_waivers_enabled: event.freedom_waivers_enabled?,
            travel_enabled: event.travel_enabled?,
            visa_options_enabled: event.visa_options_enabled?,
            visa_application_url: event.visa_application_url,
            accommodation_enabled: event.accommodation_enabled?,
            roommate_preferences_enabled: event.roommate_preferences_enabled?,
            guardian_invites_locked: event.guardian_invites_locked?,
            nfc_badges_enabled: event.nfc_badges_enabled?,
            nfc_badge_write_on_checkin_enabled: event.nfc_badge_write_on_checkin_enabled?,
            groups_enabled: event.groups_enabled?
          },
          hotel_scan_context_id: event.hotel_scan_context_id,
          participant_count: event.participant_events.size
        )
      end
    end
  end
end
