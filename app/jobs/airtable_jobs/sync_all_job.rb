module AirtableJobs
  class SyncAllJob < ApplicationJob
    queue_as :default

    # StandardError, not just Airtable::Error: a misconfigured event can fail
    # before any request is made (e.g. a blank API key raising ArgumentError in
    # Client#initialize), and an unrescued error kills the run for every event
    # after it while recording nothing on the one that broke.
    def perform
      Event.with_airtable_sync_active.find_each do |event|
        sync_event(event)
      rescue StandardError => e
        handle_failure(event, e)
      end
    end

    private

    def sync_event(event)
      service = Airtable::SyncService.new(event)
      service.sync_via_api(event.airtable_sync_table_id, event.airtable_sync_source_id)
      event.update_columns(airtable_synced_at: Time.current, airtable_sync_error: nil, airtable_sync_error_at: nil)
    end

    # One event failing must not stop the rest of the run. Pause this event's
    # sync on the first failure and tell whoever last saved its credentials:
    # every failure mode we've seen here (stale sync ids, revoked token, blank
    # key) needs a human to fix the config, so re-running every 5 minutes only
    # produces thousands of identical errors while nobody is told.
    def handle_failure(event, error)
      Rails.logger.error("[AirtableSyncAll] Paused event #{event.id}: #{error.message}")
      event.pause_airtable_sync!(error.message)

      recipient = notify_config_owner(event, error)
      report_to_sentry(event, error, recipient)
    end

    # A broken mailer must not take the rest of the run down with it — this
    # method is already running inside the loop's rescue.
    def notify_config_owner(event, error)
      recipient = event.airtable_config_last_saved_by
      return nil if recipient&.email.blank?

      AirtableMailer.sync_paused(
        event: event,
        recipient: recipient,
        error_message: error.message
      ).deliver_later

      recipient
    rescue StandardError => e
      Rails.logger.error("[AirtableSyncAll] Could not notify owner of event #{event.id}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      nil
    end

    def report_to_sentry(event, error, recipient)
      return unless defined?(Sentry)

      Sentry.capture_exception(
        error,
        tags: {
          job: "airtable_sync_all",
          event_slug: event.slug,
          airtable_status: error.respond_to?(:status) ? error.status : nil,
          airtable_sync_paused: true
        },
        contexts: {
          airtable_sync: {
            event_id: event.id,
            event_name: event.name,
            table_id: event.airtable_sync_table_id,
            sync_source_id: event.airtable_sync_source_id,
            base_id: event.airtable_base_id,
            last_synced_at: event.airtable_synced_at&.iso8601,
            paused_at: event.airtable_sync_paused_at&.iso8601,
            notified: recipient&.email || "nobody (no known config owner)"
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
