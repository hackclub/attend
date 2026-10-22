module AirtableJobs
  class SyncAllJob < ApplicationJob
    queue_as :default

    # Errors only a human can fix: the token, the base or the sync endpoint is
    # wrong, or (ArgumentError) a key or base id is missing before any request
    # is made. Everything else (rate limits, 5xx, timeouts, a dropped
    # connection) is treated as passing and retried on the next run.
    CONFIG_ERRORS = [
      Airtable::AuthenticationError,
      Airtable::ForbiddenError,
      Airtable::NotFoundError,
      Airtable::ValidationError,
      ArgumentError
    ].freeze

    # With an event_id, syncs just that event ("Sync Now", saving the
    # settings); the schedule passes none and syncs every active event.
    #
    # StandardError, not just Airtable::Error: an unrescued error kills the run
    # for every event after it while recording nothing on the one that broke.
    def perform(event_id = nil)
      events = Event.with_airtable_sync_active.includes(:airtable_connection)
      events = events.where(id: event_id) if event_id

      events.find_each do |event|
        sync_event(event)
      rescue *CONFIG_ERRORS => e
        handle_config_error(event, e)
      rescue StandardError => e
        handle_transient_error(event, e)
      end
    end

    private

    def sync_event(event)
      service = Airtable::SyncService.new(event)
      if event.airtable_sync_via_records?
        service.sync_via_records
      else
        service.sync_via_api(event.airtable_sync_table_id, event.airtable_sync_source_id)
      end
      event.record_airtable_sync_success!
    end

    # One event failing must not stop the rest of the run. Broken config
    # pauses this event's sync on the first failure and tells whoever last
    # saved its credentials, because re-running every 5 minutes only produces
    # thousands of identical errors while nobody is told.
    def handle_config_error(event, error)
      Rails.logger.error("[AirtableSyncAll] Paused event #{event.id}: #{error.message}")
      event.pause_airtable_sync!(error.message)

      recipient = notify_config_owner(event, error, mail: :sync_paused)
      report_to_sentry(event, error, recipient)
    end

    # A passing error keeps the schedule running. It is only worth a person's
    # attention once it has lasted (Event#airtable_sync_alert_due?), and then
    # only once until the sync next succeeds.
    def handle_transient_error(event, error)
      Rails.logger.warn("[AirtableSyncAll] Sync failed for event #{event.id}, retrying next run: #{error.message}")
      event.record_airtable_sync_failure!(error.message)
      return unless event.airtable_sync_alert_due?

      event.mark_airtable_sync_alerted!
      recipient = notify_config_owner(event, error, mail: :sync_failing)
      report_to_sentry(event, error, recipient)
    end

    # A broken mailer must not take the rest of the run down with it — this
    # method is already running inside the loop's rescue.
    def notify_config_owner(event, error, mail:)
      recipient = event.airtable_config_last_saved_by
      return nil if recipient&.email.blank?

      AirtableMailer.public_send(mail,
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
          airtable_sync_paused: event.airtable_sync_paused?
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
            consecutive_failures: event.airtable_sync_failures,
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
