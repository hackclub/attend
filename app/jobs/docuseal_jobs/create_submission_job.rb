module DocusealJobs
  class CreateSubmissionJob < ApplicationJob
    queue_as :default

    def perform(consent_id)
      consent = Consent.find(consent_id)
      return if consent.signed? || consent.voided?

      client = Docuseal::Client.for(consent)
      participant = consent.participant
      guardian = consent.guardian

      submitters = build_submitters(participant, guardian)
      template_id = template_id_for(consent)

      result = client.create_submission(
        template_id: template_id,
        submitters: submitters,
        metadata: {
          consent_id: consent.id,
          consent_type: consent.consent_type,
          participant_event_id: consent.participant_event_id
        }
      )

      first_submitter = result.first

      consent.update!(
        status: :sent,
        docuseal_envelope_id: first_submitter&.dig("submission_id"),
        sent_at: Time.current
      )
    rescue Docuseal::RateLimitError => e
      Rails.logger.warn("Docuseal rate limit hit, retrying in 30 seconds")
      self.class.set(wait: 30.seconds).perform_later(consent_id)
    rescue Docuseal::ValidationError => e
      consent.update!(status: :failed, failure_reason: "validation_error: #{e.message}")
      Rails.logger.error("Docuseal validation error: #{e.message}")
    rescue Docuseal::Error => e
      consent.update!(status: :failed, failure_reason: "docuseal_error: #{e.message}")
      Rails.logger.error("Docuseal submission failed for consent #{consent_id}: #{e.message}")
      raise
    end

    private

    def build_submitters(participant, guardian)
      submitters = []

      if guardian.present?
        submitters << {
          email: guardian.email,
          name: guardian.full_name,
          role: "guardian"
        }
      end

      if participant.present? && participant.email.present?
        submitters << {
          email: participant.email,
          name: participant.full_name,
          role: "participant"
        }
      end

      submitters
    end

    def template_id_for(consent)
      event = consent.event

      case consent.consent_type
      when "event_consent"
        event.docuseal_consent_template_id
      when "waiver"
        event.docuseal_waiver_template_id
      when "participant_agreement"
        event.docuseal_participant_template_id
      else
        Rails.application.credentials.dig(:docuseal, :templates, consent.consent_type.to_sym)
      end
    end
  end
end
