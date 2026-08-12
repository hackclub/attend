module DocusealJobs
  class CreateMinorWaiverJob < ApplicationJob
    queue_as :default

    DEFAULT_TEMPLATE_ID = 2274072

    def perform(consent_id)
      consent = Consent.find(consent_id)
      return if consent.signed? || consent.voided?
      # Idempotency: the waiver page may enqueue this again while an earlier
      # run is in flight — never create a second DocuSeal submission.
      return if consent.docuseal_participant_slug.present?

      participant_event = consent.participant_event
      guardian_participant_event = consent.guardian_participant_event || participant_event.guardian_participant_events.first
      return unless guardian_participant_event

      participant = participant_event.participant
      guardian = guardian_participant_event.guardian
      emergency_contacts = guardian_participant_event.emergency_contacts.order(:priority)
      event = participant_event.event

      client = Docuseal::Client.for(consent)
      template_id = template_id_for(participant_event)

      # Fetch template to get correct role and field names (varies by template)
      template = client.get_template(template_id)
      Rails.logger.info("DocuSeal template response keys: #{template.keys}")
      Rails.logger.info("DocuSeal template fields raw: #{template['fields'].inspect}")
      submitter_roles = template["submitters"]&.map { |s| s["name"] } || []
      template_fields = template["fields"]&.map { |f| f["name"] } || []
      Rails.logger.info("DocuSeal parsed template_fields: #{template_fields.inspect}")

      guardian_role = submitter_roles.find { |r| r.downcase.include?("guardian") } || "Legal Guardian"
      attendee_role = submitter_roles.find { |r| r.downcase.include?("attendee") } || "Attendee"

      # Build context for field mapping
      context = {
        participant: participant,
        guardian: guardian,
        emergency_contacts: emergency_contacts,
        event: event
      }

      # Try to use configured field mappings, fallback to fuzzy matching
      field_mapper = Docuseal::FieldMapper.new(event: event, template_type: "waiver")

      if field_mapper.has_mappings?
        Rails.logger.info("DocuSeal using configured field mappings for waiver")
        attendee_field_values = field_mapper.build_fields_for_role(role: attendee_role, context: context)
        guardian_field_values = field_mapper.build_fields_for_role(role: guardian_role, context: context)
      else
        Rails.logger.info("DocuSeal using fuzzy field matching (no configured mappings)")
        attendee_field_values = attendee_fields_fuzzy(participant, template_fields)
        guardian_field_values = guardian_fields_fuzzy(guardian, template_fields)
      end

      result = client.create_submission(
        template_id: template_id,
        send_email: false,
        order: "preserved",
        submitters: [
          {
            role: attendee_role,
            email: participant.email,
            name: participant.full_name,
            fields: attendee_field_values
          },
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

      participant_submitter = result.find { |s| s["role"] == attendee_role } || result[0]
      guardian_submitter = result.find { |s| s["role"] == guardian_role } || result[1]

      consent.update!(
        status: :sent,
        docuseal_envelope_id: participant_submitter["submission_id"],
        docuseal_participant_slug: participant_submitter["slug"],
        docuseal_guardian_slug: guardian_submitter["slug"],
        guardian_participant_event: guardian_participant_event,
        pending_on: "participant",
        sent_at: Time.current
      )

      # Send email to teen with their signing link
      ParticipantMailer.waiver_ready(participant_event: participant_event).deliver_later
    rescue Docuseal::RateLimitError => e
      Rails.logger.warn("Docuseal rate limit hit, retrying in 30 seconds")
      self.class.set(wait: 30.seconds).perform_later(consent_id)
    rescue Docuseal::ValidationError => e
      consent.update!(status: :failed, failure_reason: "validation_error: #{e.message}")
      Rails.logger.error("Docuseal validation error: #{e.message}")
    rescue Docuseal::Error => e
      consent.update!(status: :failed, failure_reason: "docuseal_error: #{e.message}")
      Rails.logger.error("Docuseal minor waiver failed for consent #{consent_id}: #{e.message}")
      raise
    end

    private

    def template_id_for(participant_event)
      event = participant_event.event
      event.docuseal_waiver_template_id.presence || DEFAULT_TEMPLATE_ID
    end

    # Fallback fuzzy matching for backwards compatibility
    def guardian_fields_fuzzy(guardian, template_fields)
      fields = []

      name_field = template_fields.find { |f| f.downcase.include?("guardian") && f.downcase.include?("name") && !f.downcase.include?("phone") } ||
                   template_fields.find { |f| f.downcase.include?("parent") && f.downcase.include?("name") && !f.downcase.include?("phone") }
      fields << { name: name_field, default_value: guardian.full_name, readonly: true } if name_field

      phone_field = template_fields.find { |f| f.downcase.include?("guardian") && f.downcase.include?("phone") } ||
                    template_fields.find { |f| f.downcase.include?("parent") && f.downcase.include?("phone") }
      fields << { name: phone_field, default_value: guardian.phone, readonly: true } if phone_field

      fields
    end

    def attendee_fields_fuzzy(participant, template_fields)
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
