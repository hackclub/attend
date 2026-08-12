class SendPendingGuardianInvitesJob < ApplicationJob
  queue_as :default

  # Participants who submitted onboarding but have no signable waiver: none was
  # created because they submitted while guardian invites were locked (minors
  # sit in awaiting_guardian; adults never leave in_progress), or a waiver row
  # exists but its DocuSeal submission never materialised.
  def self.participant_events_needing_waivers(event)
    submitted = event.participant_events
      .where(status: [ :in_progress, :awaiting_guardian ])
      .where.not(code_of_conduct_accepted_at: nil)

    waivers = Consent.waiver
    submitted
      .where.not(id: waivers.select(:participant_event_id))
      .or(submitted.where(id: waivers.where(status: [ :pending, :failed ], docuseal_participant_slug: nil).select(:participant_event_id)))
  end

  # Guardians of submitted minors who were never sent an invite, plus invites
  # that expired before the guardian ever opened the portal — those links are
  # dead, and re-sending delivers the same token with a fresh validity window.
  def self.gpes_needing_invites(event)
    awaiting = GuardianParticipantEvent
      .joins(:participant_event)
      .where(participant_events: { event_id: event.id, status: :awaiting_guardian })

    awaiting.where(invite_token_sent_at: nil)
      .or(awaiting.where(accepted_at: nil)
                  .where(invite_token_sent_at: ...GuardianParticipantEvent::INVITE_VALIDITY.ago))
  end

  def perform(event_id)
    event = Event.find(event_id)

    # The lock may have been flipped back on between enqueue (at unlock) and
    # this run — sending waivers/invites then would defeat the re-lock.
    return if event.guardian_invites_locked?

    pending_participant_events = self.class.participant_events_needing_waivers(event)

    Rails.logger.info("[SendPendingGuardianInvitesJob] Creating waivers for #{pending_participant_events.count} participant_events for event #{event.id}")

    pending_participant_events.find_each do |pe|
      create_waiver_and_notify(pe)
    end

    pending_gpes = self.class.gpes_needing_invites(event)

    Rails.logger.info("[SendPendingGuardianInvitesJob] Sending #{pending_gpes.count} guardian invites for event #{event.id}")

    pending_gpes.find_each do |gpe|
      GuardianMailer.invitation(guardian_participant_event: gpe).deliver_later
      Rails.logger.info("[SendPendingGuardianInvitesJob] Sent invite for GPE #{gpe.id}")
    end
  end

  private

  def create_waiver_and_notify(participant_event)
    if participant_event.requires_guardian?
      guardian_participant_event = participant_event.guardian_participant_events.first
      return unless guardian_participant_event

      consent = participant_event.consents.find_or_create_by!(consent_type: :waiver) do |c|
        c.status = :pending
        c.guardian_participant_event = guardian_participant_event
      end

      unless consent.signed? || consent.sent? || consent.docuseal_participant_slug.present?
        DocusealJobs::CreateMinorWaiverJob.perform_later(consent.id)
        ParticipantMailer.waiver_ready(participant_event: participant_event).deliver_later(wait: 30.seconds)
        Rails.logger.info("[SendPendingGuardianInvitesJob] Created minor waiver and sent notification for PE #{participant_event.id}")
      end
    else
      consent = participant_event.consents.find_or_create_by!(consent_type: :waiver) do |c|
        c.status = :pending
      end

      unless consent.signed? || consent.docuseal_participant_slug.present?
        DocusealJobs::CreateAdultWaiverJob.perform_later(consent.id)
        ParticipantMailer.waiver_ready(participant_event: participant_event).deliver_later(wait: 30.seconds)
        Rails.logger.info("[SendPendingGuardianInvitesJob] Created adult waiver and sent notification for PE #{participant_event.id}")
      end
    end
  end
end
