module Guardians
  # Replaces a guardian on a registration with a different person, directly,
  # without the participant asking first: "Dad did the portal, but Mum is the
  # one who should have". Guardians::Replacement does the swap; this adds who
  # may do it, the audit row and the invite.
  #
  # Global admins only (ParticipantEventPolicy#replace_guardian?). It throws
  # away signed waivers and documents, so it is held tighter than editing a
  # guardian or resending their invite.
  #
  # The new guardian is invited straight away when the registration is
  # waiting on them (submitted, invites unlocked). Otherwise they are invited
  # the usual way: when the participant submits, or when invites unlock.
  class Replace < ApplicationOperation
    include LinkLookup

    REQUIRED = %w[legal_first_name legal_last_name email].freeze

    audit_actions :replace_guardian

    # `guardian_participant_event` is the link being replaced, or its id.
    # `attributes`: legal_first_name, legal_last_name, email, optional phone
    # and relationship.
    def initialize(context, participant_event:, guardian_participant_event:, attributes:)
      super(context)
      @participant_event = participant_event
      @link_reference = guardian_participant_event
      @attributes = attributes.to_h.stringify_keys.transform_values { |value| value.to_s.squish }
      @attributes["email"] = @attributes["email"].downcase if @attributes["email"]
    end

    def precheck
      authorize!(@participant_event, :replace_guardian?)

      unless context.can_view_pii?
        return failure(:pii_restricted, "Your role can't see guardian contact details.")
      end

      unless @participant_event.requires_guardian?
        return failure(:no_guardian_required, "This registration doesn't need a guardian, so there is nobody to replace.")
      end

      link

      missing = REQUIRED.select { |field| @attributes[field].blank? }
      if missing.any?
        return failure(:missing_details, "The new guardian needs a #{missing.map(&:humanize).map(&:downcase).to_sentence}.")
      end

      return unless Replacement.needs_manual_follow_up?(@participant_event)

      failure(:manual_follow_up,
        "A guardian-signed paper document is attached. Preserve and replace it by hand before changing the guardian.")
    end

    private

    def perform
      old_link_id = link.id
      old_guardian_id = link.guardian_id
      old_status = link.status

      replacement = Replacement.new(
        participant_event: @participant_event,
        old_link: link,
        attributes: @attributes.slice("legal_first_name", "legal_last_name", "email", "phone").compact_blank,
        relationship: @attributes["relationship"].presence
      )
      new_link = replacement.call

      event = @participant_event.event
      locked = event.guardian_invites_locked?
      invite = !locked && @participant_event.reload.awaiting_guardian?

      # Only once the swap is committed: the jobs read it, and a run that
      # rolls back must not email anyone.
      ActiveRecord.after_all_transactions_commit do
        GuardianMailer.invitation(guardian_participant_event: new_link).deliver_later if invite
        Replacement.enqueue_custom_documents(@participant_event) unless locked
      end

      audit!(:replace_guardian, new_link,
        changed_fields: { "guardian_id" => [ old_guardian_id, new_link.guardian_id ] },
        metadata: {
          participant_event_id: @participant_event.id,
          replaced_guardian_participant_event_id: old_link_id,
          replaced_guardian_status: old_status,
          reset_consent_ids: replacement.reset_consents.map(&:id),
          invited: invite
        })
      success(Outcome.new(new_link, invite, replacement.reset_consents))
    end

    Outcome = Struct.new(:link, :invited, :reset_consents) do
      def invited? = invited
    end
  end
end
