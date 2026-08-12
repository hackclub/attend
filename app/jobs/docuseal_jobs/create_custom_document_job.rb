module DocusealJobs
  class CreateCustomDocumentJob < ApplicationJob
    queue_as :default

    # initiated_by tells us which side is currently on a signing page; it
    # controls whether DocuSeal emails the guardian their signing link.
    def perform(consent_id, initiated_by = "participant")
      consent = Consent.find(consent_id)
      return if consent.signed? || consent.voided?
      # Idempotency: the signing page may enqueue this again while an earlier
      # run is in flight — never create a second DocuSeal submission.
      return if consent.docuseal_envelope_id.present?

      custom_document = consent.custom_document
      return unless custom_document
      # Physical documents are signed on paper and never touch DocuSeal.
      return if custom_document.physical?

      participant_event = consent.participant_event
      participant = participant_event.participant
      guardian_participant_event = consent.guardian_participant_event || participant_event.guardian_participant_events.first
      guardian = guardian_participant_event&.guardian
      event = participant_event.event

      if custom_document.signed_by_guardian? && guardian.nil?
        consent.update!(status: :failed, failure_reason: "no_guardian_available")
        return
      end

      signers = resolve_signers(custom_document, guardian)

      client = Docuseal::Client.for(consent)
      template = client.get_template(custom_document.docuseal_template_id)
      submitter_roles = template["submitters"]&.map { |s| s["name"] } || []

      participant_role, guardian_role = resolve_roles(signers, submitter_roles)

      context = {
        participant: participant,
        guardian: guardian,
        emergency_contacts: guardian_participant_event&.emergency_contacts&.order(:priority),
        event: event
      }
      field_mapper = custom_document.field_mapper

      submitters = signers.map do |signer|
        if signer == :participant
          {
            role: participant_role,
            email: participant.email,
            name: participant.full_name,
            fields: field_mapper.build_fields_for_role(role: participant_role, context: context),
            # Participants sign embedded in Attend, so DocuSeal shouldn't email them.
            send_email: false
          }
        else
          {
            role: guardian_role,
            email: guardian.email,
            name: guardian.full_name,
            fields: field_mapper.build_fields_for_role(role: guardian_role, context: context),
            # A guardian on the portal signs embedded right away; otherwise
            # DocuSeal emails them their link (after the participant, if both sign).
            send_email: initiated_by != "guardian"
          }
        end
      end

      result = client.create_submission(
        template_id: custom_document.docuseal_template_id,
        send_email: false,
        order: "preserved",
        submitters: submitters,
        metadata: {
          consent_id: consent.id,
          consent_type: consent.consent_type,
          custom_document_id: custom_document.id,
          participant_event_id: consent.participant_event_id
        }
      )

      participant_submitter = result.find { |s| s["role"] == participant_role } if signers.include?(:participant)
      guardian_submitter = result.find { |s| s["role"] == guardian_role } if signers.include?(:guardian)

      consent.update!(
        status: :sent,
        docuseal_envelope_id: result.first&.dig("submission_id"),
        docuseal_template_id: custom_document.docuseal_template_id,
        docuseal_participant_slug: participant_submitter&.dig("slug"),
        docuseal_guardian_slug: guardian_submitter&.dig("slug"),
        guardian_participant_event: signers.include?(:guardian) ? guardian_participant_event : consent.guardian_participant_event,
        pending_on: signers.first.to_s,
        sent_at: Time.current
      )
    rescue Docuseal::RateLimitError
      Rails.logger.warn("Docuseal rate limit hit, retrying in 30 seconds")
      self.class.set(wait: 30.seconds).perform_later(consent_id)
    rescue Docuseal::ValidationError => e
      consent.update!(status: :failed, failure_reason: "validation_error: #{e.message}")
      Rails.logger.error("Docuseal validation error: #{e.message}")
    rescue Docuseal::Error => e
      consent.update!(status: :failed, failure_reason: "docuseal_error: #{e.message}")
      Rails.logger.error("Docuseal custom document failed for consent #{consent_id}: #{e.message}")
      raise
    end

    private

    # Which parties end up on the DocuSeal submission. Dual-signer documents
    # fall back to participant-only when there is no guardian.
    def resolve_signers(custom_document, guardian)
      case custom_document.signer_type
      when "participant"
        [ :participant ]
      when "guardian"
        [ :guardian ]
      when "participant_and_guardian", "minor_and_guardian"
        guardian ? [ :participant, :guardian ] : [ :participant ]
      end
    end

    # Custom templates name their roles however the author liked, so match
    # loosely and fall back to positional roles for whoever must sign.
    def resolve_roles(signers, submitter_roles)
      participant_role = submitter_roles.find { |r| r.match?(/attendee|participant/i) }
      guardian_role = submitter_roles.find { |r| r.match?(/guardian|parent/i) }

      if signers == [ :participant ]
        participant_role ||= submitter_roles.first || "Attendee"
      elsif signers == [ :guardian ]
        guardian_role ||= submitter_roles.first || "Legal Guardian"
      else
        participant_role ||= (submitter_roles - [ guardian_role ].compact).first || "Attendee"
        guardian_role ||= (submitter_roles - [ participant_role ]).first || "Legal Guardian"
      end

      [ participant_role, guardian_role ]
    end
  end
end
