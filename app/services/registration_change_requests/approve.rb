module RegistrationChangeRequests
  class Approve
    IDENTITY_FIELDS = %w[legal_first_name legal_last_name date_of_birth].freeze
    GUARDIAN_FIELDS = %w[legal_first_name legal_last_name email phone relationship].freeze
    RESET_FIELDS = {
      status: :pending,
      docuseal_envelope_id: nil,
      docuseal_participant_slug: nil,
      docuseal_guardian_slug: nil,
      docuseal_template_id: nil,
      participant_signed_at: nil,
      guardian_signed_at: nil,
      signed_at: nil,
      document_url: nil,
      failure_reason: nil,
      pending_on: nil,
      sent_at: nil
    }.freeze

    def self.call(request:, reviewer:)
      new(request: request, reviewer: reviewer).call
    end

    def initialize(request:, reviewer:)
      @request = request
      @reviewer = reviewer
    end

    def call
      result = nil

      RegistrationChangeRequest.transaction do
        request.lock!
        raise ArgumentError, "Request has already been resolved" unless request.pending?

        result = case request.kind
        when "signed_identity" then approve_identity
        when "guardian" then approve_guardian
        when "support" then mark_approved
        end
      end

      enqueue_guardian_work if result == :approved && request.guardian?
      result
    end

    private

    attr_reader :request, :reviewer

    def approve_identity
      if identity_bound_acceptance_exists?
        return mark_follow_up(
          "This identity is shared across events with signed registrations. Staff must review and reset every affected registration before applying it."
        )
      end

      attributes = request.requested_changes.slice(*IDENTITY_FIELDS)
      raise ArgumentError, "No supported identity changes were requested" if attributes.empty?

      request.participant.update!(attributes)
      mark_approved
    end

    def identity_bound_acceptance_exists?
      registrations = request.participant.participant_events
      return true if registrations.where.not(code_of_conduct_accepted_at: nil).exists?

      Consent.where(participant_event_id: registrations.select(:id))
        .where("signed_at IS NOT NULL OR participant_signed_at IS NOT NULL OR guardian_signed_at IS NOT NULL")
        .exists?
    end

    def approve_guardian
      participant_event = request.participant_event
      old_link = participant_event.primary_guardian || participant_event.guardian_participant_events.first
      unless participant_event.requires_guardian? && old_link
        return mark_follow_up(
          "This registration no longer has an eligible guardian to replace. Staff must review it manually."
        )
      end

      if guardian_change_needs_manual_follow_up?
        return mark_follow_up(
          "A guardian-signed paper document is attached. Staff must preserve and replace it manually before changing the guardian."
        )
      end

      attributes = request.requested_changes.slice(*GUARDIAN_FIELDS)
      relationship = attributes.delete("relationship")
      guardian = Guardian.new(attributes)
      validate_guardian_separation!(guardian, participant_event.participant)
      guardian.save!

      new_link = participant_event.guardian_participant_events.create!(
        guardian: guardian,
        relationship: relationship,
        is_primary_guardian: old_link&.is_primary_guardian? || participant_event.guardian_participant_events.none?,
        status: :pending,
        invite_token_sent_at: nil,
        invite_last_used_at: nil
      )

      guardian_dependent_consents.each do |consent|
        consent.update!(RESET_FIELDS.merge(guardian_participant_event: new_link))
      end
      old_link.emergency_contacts.find_each do |emergency_contact|
        emergency_contact.update!(guardian_participant_event: new_link)
      end
      participant_event.safeguarding_info&.update!(freedom_waiver_granted: false)
      old_link&.destroy!
      participant_event.update!(status: :awaiting_guardian)
      mark_approved
    end

    def validate_guardian_separation!(guardian, participant)
      participant_email = participant.email.to_s.strip.downcase
      guardian_email = guardian.email.to_s.strip.downcase
      if guardian_email.present? && guardian_email == participant_email
        guardian.errors.add(:email, "cannot be the same as the participant's email address")
      end

      participant_phone = PhoneNormalizer.normalize(participant.phone)
      guardian_phone = PhoneNormalizer.normalize(guardian.phone)
      if guardian_phone.present? && guardian_phone == participant_phone
        guardian.errors.add(:phone, "cannot be the same as the participant's phone number")
      end

      raise ActiveRecord::RecordInvalid, guardian if guardian.errors.any?
    end

    def guardian_dependent_consents
      request.participant_event.consents.includes(:custom_document).select do |consent|
        consent.waiver? || consent.freedom_waiver? || consent.custom_document&.guardian_signs?
      end
    end

    def guardian_change_needs_manual_follow_up?
      guardian_dependent_consents.any? do |consent|
        consent.custom_document&.physical? && consent.physical_uploads.attached?
      end
    end

    def mark_approved
      request.update!(status: :approved, resolved_by: reviewer, resolved_at: Time.current)
      :approved
    end

    def mark_follow_up(message)
      request.update!(
        status: :follow_up_needed,
        staff_response: message,
        resolved_by: reviewer,
        resolved_at: Time.current
      )
      :follow_up_needed
    end

    def enqueue_guardian_work
      return if request.event.guardian_invites_locked?

      SendPendingGuardianInvitesJob.perform_later(request.participant_event.event_id)
      guardian_dependent_consents.each do |consent|
        next unless consent.custom_document&.electronic?

        DocusealJobs::CreateCustomDocumentJob.perform_later(consent.id)
      end
    end
  end
end
