module RegistrationChangeRequests
  class Approve
    IDENTITY_FIELDS = %w[legal_first_name legal_last_name date_of_birth].freeze
    GUARDIAN_FIELDS = %w[legal_first_name legal_last_name email phone relationship].freeze
    # Set automatically, so it is written for staff. Participants see a
    # generic "staff will be in touch" message instead (see #mark_follow_up).
    SHARED_IDENTITY_FOLLOW_UP = "This identity is shared across events with signed registrations. " \
      "Staff must review and reset every affected registration before applying it.".freeze

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

      if result == :approved
        enqueue_guardian_work if request.guardian?
        RegistrationCorrectionMailer.participant_approved(change_request: request).deliver_later
      end
      result
    end

    private

    attr_reader :request, :reviewer

    def approve_identity
      if identity_bound_acceptance_exists?
        return mark_follow_up(SHARED_IDENTITY_FOLLOW_UP, reason: "shared_identity")
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

      details = GuardianDetails.new(participant_event, request.requested_changes.slice(*GUARDIAN_FIELDS))
      if details.same_person?
        # The guardian row is shared with a sibling's registration: editing it
        # here would silently change that registration's guardian too.
        if details.current_guardian.guardian_participant_events.where.not(id: details.current_link.id).exists?
          return mark_follow_up(
            "This guardian is also linked to another registration. Staff must update their details manually " \
            "so the other registration isn't changed by accident."
          )
        end

        return correct_guardian_in_place(details)
      end

      attributes = details.normalized_changes
      Guardians::Replacement.new(
        participant_event: participant_event,
        old_link: old_link,
        attributes: attributes.except("relationship"),
        relationship: attributes["relationship"]
      ).call
      mark_approved
    end

    # The participant mistyped their own guardian's details. Fix the guardian
    # record and keep everything they have already signed: the person who
    # signed is the person on file. Only an unsigned guardian with a new email
    # address needs the invite sending again.
    def correct_guardian_in_place(details)
      @corrected_in_place = true
      link = details.current_link
      guardian = link.guardian
      attributes = details.normalized_changes.slice("legal_first_name", "legal_last_name", "email", "phone")
        .transform_values { |value| value.to_s.squish }
        .compact_blank
      guardian.assign_attributes(attributes)
      validate_guardian_separation!(guardian, request.participant_event.participant)
      email_changed = guardian.email_changed?
      guardian.save!

      relationship = details.changes["relationship"].to_s.squish
      link.update!(relationship: relationship) if relationship.present?
      @resend_invite_to = link if email_changed && !link.completed?
      # The old link went to the wrong address. Revoking (not just unstamping)
      # kills it and makes the resent invite carry a fresh token.
      link.revoke_invite_token! if @resend_invite_to
      mark_approved
    end

    def validate_guardian_separation!(guardian, participant)
      Guardians::Replacement.validate_separation!(guardian, participant)
    end

    def guardian_dependent_consents
      Guardians::Replacement.dependent_consents(request.participant_event)
    end

    def guardian_change_needs_manual_follow_up?
      Guardians::Replacement.needs_manual_follow_up?(request.participant_event)
    end

    def mark_approved
      request.update!(status: :approved, resolved_by: reviewer, resolved_at: Time.current)
      :approved
    end

    # reason marks a note Approve wrote for staff rather than one staff wrote
    # for the participant (see RegistrationChangeRequest#awaiting_staff_reset?).
    def mark_follow_up(message, reason: nil)
      request.update!(
        status: :follow_up_needed,
        staff_response: message,
        follow_up_reason: reason,
        resolved_by: reviewer,
        resolved_at: Time.current
      )
      :follow_up_needed
    end

    def enqueue_guardian_work
      return if request.event.guardian_invites_locked?

      if @corrected_in_place
        GuardianMailer.invitation(guardian_participant_event: @resend_invite_to).deliver_later if @resend_invite_to
        return
      end

      SendPendingGuardianInvitesJob.perform_later(request.participant_event.event_id)
      Guardians::Replacement.enqueue_custom_documents(request.participant_event)
    end
  end
end
