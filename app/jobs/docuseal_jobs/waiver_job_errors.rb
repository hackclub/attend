module DocusealJobs
  # Error handling shared by the Create*WaiverJobs.
  #
  # - Transient trouble (DocuSeal 5xx, connection failures, timeouts) retries
  #   with backoff. The consent stays pending meanwhile, so the portal doesn't
  #   reset and re-enqueue it on top of the retry; only once the retries run
  #   out is it marked failed and the error reported.
  # - A missing or unconfigured template is a config problem no retry fixes:
  #   the consent is marked failed with a template_* reason (shown on the
  #   admin consents page) and the job finishes without raising.
  #   Docuseal::WaiverTemplate.retry_failed? keeps the portal from re-sending
  #   it until the event's template changes.
  module WaiverJobErrors
    extend ActiveSupport::Concern

    TRANSIENT_ERRORS = [ Docuseal::ServerError, Faraday::ConnectionFailed, Faraday::TimeoutError ].freeze

    included do
      retry_on(*TRANSIENT_ERRORS, wait: :polynomially_longer, attempts: 5) do |job, error|
        job.mark_consent_failed!("docuseal_error: #{error.message}")
        raise error
      end
    end

    def mark_consent_failed!(reason, template_id: nil)
      consent = Consent.find_by(id: arguments.first)
      return unless consent
      return if consent.signed? || consent.voided?

      attributes = { status: :failed, failure_reason: reason.truncate(250) }
      attributes[:docuseal_template_id] = template_id.to_s if template_id
      consent.update!(attributes)
    end

    private

    def fail_unconfigured_template!(consent, kind)
      Rails.logger.error(
        "[#{self.class.name}] No DocuSeal #{kind} template configured for event #{consent.participant_event.event_id} " \
        "on #{consent.docuseal_host.presence || 'the default host'}; consent #{consent.id} marked failed"
      )
      mark_consent_failed!("template_not_configured: no #{kind.to_s.humanize(capitalize: false)} template is set for this event")
    end

    def fail_missing_template!(consent, template_id)
      Rails.logger.error(
        "[#{self.class.name}] DocuSeal template #{template_id} not found on #{consent.docuseal_host.presence || 'the default host'} " \
        "(event #{consent.participant_event.event_id}); consent #{consent.id} marked failed"
      )
      mark_consent_failed!("template_not_found: DocuSeal template #{template_id} doesn't exist on #{Docuseal.host(consent.docuseal_host)}",
        template_id: template_id)
    end
  end
end
