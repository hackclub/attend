module Guardians
  # Corrects a guardian's details on one registration's guardian link.
  #
  # A changed email kills the portal link that went to the old address, unless
  # the guardian has already finished (GuardianParticipantEvent#revoke_invite_token!).
  # A Guardian row is shared by every registration it is linked to, so the
  # change reaches siblings too.
  #
  # The surfaces hold this to different bars today, preserved as found:
  #
  #   html  no policy check: anyone in the admin area for this event whose role
  #         there can see PII (Admin::GuardiansController#require_contact_details_access).
  #   mcp   ParticipantEventPolicy#manage_guardians? (event admins), plus a role
  #         on any event that can see PII.
  #
  # Anything that isn't the admin UI gets the stricter bar.
  class Update < ApplicationOperation
    include LinkLookup

    audit_actions :record_update

    # `guardian_participant_event` is the link or its id.
    def initialize(context, participant_event:, guardian_participant_event:, attributes:)
      super(context)
      @participant_event = participant_event
      @link_reference = guardian_participant_event
      @attributes = attributes.to_h.stringify_keys
    end

    def precheck
      authorize!(@participant_event, :manage_guardians?) unless context.html?

      unless context.can_view_pii?
        return failure(:pii_restricted, "Your role can't edit guardian contact details.")
      end

      link
      return failure(:nothing_to_update, "Nothing to update.") if @attributes.empty?

      # A guardian can't share the participant's phone (the email check lives
      # on the model).
      return unless shares_participant_phone?

      guardian.errors.add(:phone, "cannot be the same as the participant's phone number")
      failure(:phone_matches_participant, "Guardian phone cannot be the same as the participant's phone number.",
        record: guardian)
    end

    private

    def shares_participant_phone?
      participant_phone = @participant_event.participant.phone
      return false if @attributes["phone"].blank? || participant_phone.blank?

      PhoneNormalizer.normalize(@attributes["phone"]) == participant_phone
    end

    def perform
      old_email = guardian.email
      guardian.update!(@attributes)

      # Revoke rather than just unstamp: the old link went to the wrong
      # address, and clearing invite_token_sent_at alone leaves its token live
      # and makes the next invite resend the same URL.
      revoked = guardian.email != old_email && !link.completed?
      changes = guardian.previous_changes.except("created_at", "updated_at")
      link.revoke_invite_token! if revoked

      audit!(:record_update, guardian, changed_fields: changes, metadata: {
        participant_event_id: @participant_event.id,
        guardian_participant_event_id: link.id,
        invite_revoked: revoked
      })
      success(link)
    end
  end
end
