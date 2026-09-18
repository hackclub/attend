module Api
  module V1
    # Audit logging for API writes.
    #
    # An API key authenticates without a person, so the actor is the token's
    # owner — the human who issued the credential — and the token's id goes in
    # the metadata either way, so a key's writes stay attributable after a
    # rename, a rotation or a revocation. Ids, not names: audit_logs.metadata
    # is stored in clear text and an id is provably not a credential.
    module ApiAuditing
      extend ActiveSupport::Concern

      private

      def audit_api_change!(action, record, changed_fields: nil, metadata: {})
        AuditLog.log!(
          action: action,
          record: record,
          actor: current_user || current_series_api_token&.user || current_event_api_token&.user,
          event: @event,
          changed_fields: changed_fields || record.previous_changes.except("created_at", "updated_at"),
          metadata: {
            ip: request.remote_ip,
            user_agent: request.user_agent,
            source: api_audit_source,
            series_api_token_id: current_series_api_token&.id,
            event_api_token_id: current_event_api_token&.id
          }.merge(metadata).compact
        )
      rescue StandardError => e
        Rails.logger.error("[Api] Failed to write audit log: #{e.class} - #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end

      def api_audit_source
        return "series_api" if current_series_from_api_key
        return "event_api" if current_event_from_api_key

        "api"
      end
    end
  end
end
