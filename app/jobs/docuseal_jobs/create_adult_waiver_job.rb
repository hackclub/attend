module DocusealJobs
  class CreateAdultWaiverJob < ApplicationJob
    queue_as :default

    DEFAULT_TEMPLATE_ID = 2274072

    def perform(consent_id)
      consent = Consent.find(consent_id)
      return if consent.signed? || consent.voided?
      # Idempotency: the waiver page may enqueue this again while an earlier
      # run is in flight — never create a second DocuSeal submission.
      return if consent.docuseal_participant_slug.present?

      participant_event = consent.participant_event
      participant = participant_event.participant

      client = Docuseal::Client.for(consent)
      template_id = template_id_for(participant_event)

      template = client.get_template(template_id)
      submitter_roles = template["submitters"]&.map { |s| s["name"] } || []
      template_fields = template["fields"]&.map { |f| f["name"] } || []

      attendee_role = submitter_roles.find { |r| r.downcase.include?("attendee") } || "Attendee"

      result = client.create_submission(
        template_id: template_id,
        send_email: false,
        submitters: [
          {
            role: attendee_role,
            email: participant.email,
            name: participant.full_name,
            fields: participant_fields(participant, template_fields)
          }
        ],
        metadata: {
          consent_id: consent.id,
          consent_type: consent.consent_type,
          participant_event_id: consent.participant_event_id
        }
      )

      first_submitter = result.first
      participant_slug = first_submitter&.dig("slug")

      consent.update!(
        status: :sent,
        docuseal_envelope_id: first_submitter&.dig("submission_id"),
        docuseal_participant_slug: participant_slug,
        pending_on: "participant",
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
      Rails.logger.error("Docuseal adult waiver failed for consent #{consent_id}: #{e.message}")
      raise
    end

    private

    def template_id_for(participant_event)
      event = participant_event.event
      event.docuseal_waiver_template_id.presence ||
        event.docuseal_adult_waiver_template_id.presence ||
        DEFAULT_TEMPLATE_ID
    end

    def participant_fields(participant, template_fields)
      fields = []

      name_field = template_fields.find { |f| f.downcase.include?("attendee") && f.downcase.include?("name") && !f.downcase.include?("phone") && !f.downcase.include?("emergency") }
      fields << { name: name_field, default_value: participant.full_name, readonly: true } if name_field

      phone_field = template_fields.find { |f| f.downcase.include?("attendee") && f.downcase.include?("phone") }
      fields << { name: phone_field, default_value: participant.phone, readonly: true } if phone_field

      dob_field = template_fields.find { |f| f.downcase.include?("birth") || f.downcase.include?("dob") }
      fields << { name: dob_field, default_value: participant.date_of_birth&.strftime("%Y-%m-%d"), readonly: true } if dob_field && participant.date_of_birth

      fields
    end
  end
end
