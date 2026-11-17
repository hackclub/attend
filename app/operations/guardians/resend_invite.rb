module Guardians
  # Emails a guardian their portal invite again.
  #
  # ParticipantEventPolicy#manage_guardians? on every surface. Refused while
  # the event has guardian invites locked, and for an address that is bouncing.
  #
  # What happens to the link already out there differs by surface today, and
  # is preserved as found rather than unified:
  #
  #   html  rotates: the old link dies now and the email carries a new one
  #         (a staff resend is usually because the old link went astray).
  #   mcp   keeps: only the sent-at stamp is cleared, so the same link is
  #         emailed again and the old one keeps working.
  #
  # The API has no resend today; it would rotate, the more cautious of the two.
  class ResendInvite < ApplicationOperation
    include LinkLookup

    audit_actions :resend_guardian_invite

    ROTATES_TOKEN = { html: true, api: true, mcp: false }.freeze

    # `guardian_participant_event` is the link or its id.
    def initialize(context, participant_event:, guardian_participant_event:)
      super(context)
      @participant_event = participant_event
      @link_reference = guardian_participant_event
    end

    def precheck
      authorize!(@participant_event, :manage_guardians?)

      event = @participant_event.event
      if event.guardian_invites_locked?
        return failure(:invites_locked, "Guardian invites are currently locked for #{event.name}.")
      end

      return unless guardian.email_undeliverable?

      failure(:email_undeliverable, "#{guardian.email} is bouncing — correct the guardian's email before resending.")
    end

    private

    def rotate_token? = ROTATES_TOKEN.fetch(context.surface)

    def perform
      sent_at_was = link.invite_token_sent_at
      rotate_token? ? link.revoke_invite_token! : link.update!(invite_token_sent_at: nil)

      # Once the link's new state is committed: the job reads it, and a run
      # that rolls back must not email anyone.
      ActiveRecord.after_all_transactions_commit do
        GuardianMailer.invitation(guardian_participant_event: link).deliver_later
      end

      # Named fields only: the changeset also holds the token's digest, which
      # has no business in an audit row.
      audit!(:resend_guardian_invite, link,
        changed_fields: { "invite_token_sent_at" => [ sent_at_was, nil ] },
        metadata: { participant_event_id: @participant_event.id, token_rotated: rotate_token? })
      success(link)
    end
  end
end
