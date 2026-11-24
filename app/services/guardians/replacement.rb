module Guardians
  # Swaps one guardian on a registration for a different person.
  #
  # The new person gets their own Guardian row and link. Everything the old
  # guardian signed goes back to pending on the new link (a signature belongs
  # to the person who made it), emergency contacts move across rather than
  # being lost, the freedom waiver choice is cleared, and the old link is
  # removed. A submitted registration then goes back to waiting on the new
  # guardian.
  #
  # Mechanics only: no authorization, no audit row, no mail. The callers own
  # those, because they differ:
  #
  #   RegistrationChangeRequests::Approve  a participant asked, staff approved
  #   Guardians::Replace                   a global admin did it directly
  #
  # Runs inside the caller's transaction. Raises ActiveRecord::RecordInvalid
  # (carrying the guardian) when the new details don't validate.
  class Replacement
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
      documents: [],
      failure_reason: nil,
      pending_on: nil,
      sent_at: nil
    }.freeze

    def self.dependent_consents(participant_event)
      participant_event.consents.includes(:custom_document).select do |consent|
        consent.waiver? || consent.freedom_waiver? || consent.custom_document&.guardian_signs?
      end
    end

    # A guardian-signed paper document has an uploaded original that must not
    # be thrown away, so staff have to handle it by hand.
    def self.needs_manual_follow_up?(participant_event)
      dependent_consents(participant_event).any? do |consent|
        consent.custom_document&.physical? && consent.physical_uploads.attached?
      end
    end

    # Electronic guardian-signed documents need a fresh DocuSeal submission
    # for the new guardian. Waivers don't: they are generated when the
    # guardian opens the portal.
    def self.enqueue_custom_documents(participant_event)
      dependent_consents(participant_event).each do |consent|
        next unless consent.custom_document&.electronic?

        DocusealJobs::CreateCustomDocumentJob.perform_later(consent.id)
      end
    end

    def self.validate_separation!(guardian, participant)
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

    attr_reader :reset_consents

    # attributes: the new guardian's legal_first_name, legal_last_name, email
    # and phone (E.164, or anything PhoneNormalizer reads).
    def initialize(participant_event:, old_link:, attributes:, relationship: nil)
      @participant_event = participant_event
      @old_link = old_link
      @attributes = attributes.to_h.stringify_keys.slice("legal_first_name", "legal_last_name", "email", "phone")
      @relationship = relationship
      @reset_consents = []
    end

    # Returns the new GuardianParticipantEvent.
    def call
      guardian = Guardian.new(@attributes)
      self.class.validate_separation!(guardian, @participant_event.participant)
      guardian.save!

      new_link = @participant_event.guardian_participant_events.create!(
        guardian: guardian,
        relationship: @relationship,
        is_primary_guardian: @old_link.is_primary_guardian? || @participant_event.guardian_participant_events.none?,
        status: :pending,
        invite_token_sent_at: nil,
        invite_last_used_at: nil
      )

      self.class.dependent_consents(@participant_event).each do |consent|
        consent.update!(RESET_FIELDS.merge(guardian_participant_event: new_link))
        @reset_consents << consent
      end
      @old_link.emergency_contacts.find_each do |emergency_contact|
        emergency_contact.update!(guardian_participant_event: new_link)
      end
      @participant_event.safeguarding_info&.update!(freedom_waiver_granted: false)
      @old_link.destroy!
      # A submitted registration goes back to waiting on the new guardian;
      # one the participant hasn't submitted yet is still theirs to finish,
      # and the new guardian is invited when they do.
      @participant_event.sync_status!(cause: :guardian_replaced)

      new_link
    end
  end
end
