# Emails every onboarding invitation an event recorded while it was holding
# them (see Event#onboarding_invites_held?). Enqueued when the hold is
# released, and by the "send held invitations" buttons on the event and
# series pages.
class SendHeldOnboardingInvitesJob < ApplicationJob
  queue_as :default

  # Same pacing as ProcessImportBatchJob: the mail provider rate-limits, and a
  # released series can be several hundred invitations at once.
  INVITE_DELAY = 1.second

  def perform(event_id)
    event = Event.find(event_id)

    # The hold may have been put back between enqueue (at release) and this
    # run — sending then would defeat the re-hold.
    if event.onboarding_invites_held?
      Rails.logger.info("[SendHeldOnboardingInvitesJob] Skipping event #{event.id}: onboarding invitations are held again")
      return
    end

    held = event.invitations.held.order(:created_at).to_a
    Rails.logger.info("[SendHeldOnboardingInvitesJob] Sending #{held.size} held invitations for event #{event.id}")
    return if held.empty?

    participants = Participant.where("LOWER(email) IN (?)", held.map(&:email)).index_by { |p| p.email.downcase }

    sent = 0
    held.each do |invitation|
      participant = participants[invitation.email]

      # Postmark suppresses hard-bounced addresses; sending just raises
      # InactiveRecipientError. Needs the email corrected in admin first.
      if participant&.email_undeliverable?
        Rails.logger.warn("[SendHeldOnboardingInvitesJob] Skipping invitation #{invitation.id}: email is undeliverable")
        next
      end

      # A ban placed after the invitation was recorded.
      if Ban.banned?(invitation.email)
        Rails.logger.warn("[SendHeldOnboardingInvitesJob] Skipping invitation #{invitation.id}: email is banned")
        next
      end

      ParticipantMailer.invitation(
        email: invitation.email,
        name: invitation.name,
        event: event,
        participant: participant
      ).deliver_later(wait: sent * INVITE_DELAY)
      sent += 1
    end

    Rails.logger.info("[SendHeldOnboardingInvitesJob] Enqueued #{sent} of #{held.size} held invitations for event #{event.id}")
  end
end
