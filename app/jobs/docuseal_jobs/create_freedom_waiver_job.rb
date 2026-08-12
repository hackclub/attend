module DocusealJobs
  class CreateFreedomWaiverJob < ApplicationJob
    queue_as :default

    DEFAULT_TEMPLATE_ID = 2274416

    def perform(consent_id)
      consent = Consent.find(consent_id)
      return if consent.signed? || consent.voided?

      participant_event = consent.participant_event
      guardian_participant_event = consent.guardian_participant_event || participant_event.guardian_participant_events.first
      return unless guardian_participant_event

      participant = participant_event.participant
      guardian = guardian_participant_event.guardian
      event = participant_event.event

      client = Docuseal::Client.for(consent)
      template_id = template_id_for(participant_event)

      # Fetch template to get correct role and field names (varies by template)
      template = client.get_template(template_id)
      submitter_roles = template["submitters"]&.map { |s| s["name"] } || []
      template_fields = template["fields"]&.map { |f| f["name"] } || []

      guardian_role = submitter_roles.find { |r| r.downcase.include?("guardian") || r.downcase.include?("parent") } || "Parent/Legal Guardian"

      # Build context for field mapping
      context = {
        participant: participant,
        guardian: guardian,
        emergency_contacts: [],
        event: event
      }

      # Try to use configured field mappings, fallback to fuzzy matching
      field_mapper = Docuseal::FieldMapper.new(event: event, template_type: "freedom_waiver")

      if field_mapper.has_mappings?
        Rails.logger.info("DocuSeal using configured field mappings for freedom waiver")
        guardian_field_values = field_mapper.build_fields_for_role(role: guardian_role, context: context)
      else
        Rails.logger.info("DocuSeal using fuzzy field matching for freedom waiver (no configured mappings)")
        guardian_field_values = guardian_fields_fuzzy(guardian, participant, template_fields)
      end

      result = client.create_submission(
        template_id: template_id,
        send_email: false,
        order: "preserved",
        submitters: [
          {
            role: guardian_role,
            email: guardian.email,
            name: guardian.full_name,
            fields: guardian_field_values
          }
        ],
        metadata: {
          consent_id: consent.id,
          consent_type: consent.consent_type,
          participant_event_id: consent.participant_event_id,
          guardian_participant_event_id: guardian_participant_event.id
        }
      )

      guardian_submitter = result.find { |s| s["role"] == guardian_role } || result[0]

      consent.update!(
        status: :sent,
        docuseal_envelope_id: guardian_submitter["submission_id"],
        docuseal_guardian_slug: guardian_submitter["slug"],
        guardian_participant_event: guardian_participant_event,
        pending_on: "guardian",
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
      Rails.logger.error("Docuseal freedom waiver failed for consent #{consent_id}: #{e.message}")
      raise
    end

    private

    def template_id_for(participant_event)
      event = participant_event.event
      event.docuseal_freedom_waiver_template_id.presence || DEFAULT_TEMPLATE_ID
    end

    # Fallback fuzzy matching for backwards compatibility
    def guardian_fields_fuzzy(guardian, participant, template_fields)
      fields = []

      name_field = template_fields.find { |f| (f.downcase.include?("guardian") || f.downcase.include?("parent")) && f.downcase.include?("name") }
      fields << { name: name_field, default_value: guardian.full_name, readonly: true } if name_field

      child_name_field = template_fields.find { |f| f.downcase.include?("child") && f.downcase.include?("name") && !f.downcase.include?("phone") }
      fields << { name: child_name_field, default_value: participant.full_name, readonly: true } if child_name_field

      child_phone_field = template_fields.find { |f| f.downcase.include?("child") && f.downcase.include?("phone") }
      fields << { name: child_phone_field, default_value: participant.phone, readonly: true } if child_phone_field

      fields
    end
  end
end
