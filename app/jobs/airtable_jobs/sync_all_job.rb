module AirtableJobs
  class SyncAllJob < ApplicationJob
    queue_as :default

    # StandardError, not just Airtable::Error: a misconfigured event can fail
    # before any request is made (e.g. a blank API key raising ArgumentError in
    # Client#initialize), and an unrescued error kills the run for every event
    # after it while recording nothing on the one that broke.
    def perform
      events_with_sync_configured.find_each do |event|
        sync_event(event)
      rescue StandardError => e
        report_failure(event, e)
      end
    end

    private

    def events_with_sync_configured
      Event.where.not(airtable_sync_source_id: [ nil, "" ])
           .where.not(airtable_sync_table_id: [ nil, "" ])
           .where("config->>'airtable_api_key' IS NOT NULL")
           .where("config->>'airtable_base_id' IS NOT NULL")
    end

    def sync_event(event)
      service = Airtable::SyncService.new(event)
      service.sync_via_api(event.airtable_sync_table_id, event.airtable_sync_source_id)
      event.update_columns(airtable_synced_at: Time.current, airtable_sync_error: nil, airtable_sync_error_at: nil)
    end

    # One event failing must not stop the rest of the run, but a rescue that only
    # logs makes a permanently broken sync (stale ids, revoked token) look
    # identical to a healthy one. Fingerprint per event so each broken event is
    # its own Sentry issue that stays open until someone fixes the config.
    def report_failure(event, error)
      Rails.logger.error("[AirtableSyncAll] Event #{event.id}: #{error.message}")
      event.update_columns(airtable_sync_error: error.message, airtable_sync_error_at: Time.current)

      return unless defined?(Sentry)

      Sentry.capture_exception(
        error,
        tags: {
          job: "airtable_sync_all",
          event_slug: event.slug,
          airtable_status: error.respond_to?(:status) ? error.status : nil
        },
        contexts: {
          airtable_sync: {
            event_id: event.id,
            event_name: event.name,
            table_id: event.airtable_sync_table_id,
            sync_source_id: event.airtable_sync_source_id,
            base_id: event.airtable_base_id,
            last_synced_at: event.airtable_synced_at&.iso8601
          }
        },
        fingerprint: fingerprint_for(event, error)
      )
    end

    # A 5xx (after the client's retries) means Airtable is unhealthy, not that
    # this event's config is broken — group those into one issue instead of
    # opening a per-event issue for every gateway blip.
    def fingerprint_for(event, error)
      return [ "airtable-sync-all", error.class.name ] if error.is_a?(Airtable::ServerError)

      [ "airtable-sync-all", error.class.name, event.id ]
    end
  end
end
