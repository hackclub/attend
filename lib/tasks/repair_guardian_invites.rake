namespace :guardian_invites do
  desc <<~DESC
    Repair guardian invite / waiver state for one event.

    Heals participants left in-between by the invite-lock leaks and the invite
    token race (fixed in PR #338):
      1. Submitted participants with no signable waiver (minors stuck in
         awaiting_guardian, adults stuck in in_progress) — backfilled via
         SendPendingGuardianInvitesJob.
      2. Guardians never invited, or whose invite expired unopened — also via
         the job.
      3. Guardians with an unopened invite that may contain a dead link (sent
         while the token race existed: the stored token is valid, but the link
         that was emailed can 404). Re-sent here — same token, fresh window.

    ENV:
      EVENT=<slug>          required
      APPLY=1               actually enqueue waivers/emails (default: dry run)
      SENT_BEFORE=<iso8601> bucket 3 only re-sends invites sent before this
                            time, e.g. when the race fix deployed (default: all
                            unopened invites regardless of age)
  DESC
  task repair: :environment do
    event = Event.find_by!(slug: ENV.fetch("EVENT"))
    apply = ENV["APPLY"] == "1"
    sent_before = ENV["SENT_BEFORE"].present? ? Time.zone.parse(ENV["SENT_BEFORE"]) : Time.current

    if event.guardian_invites_locked?
      abort "Guardian invites are still locked for #{event.name} — unlock the event first (nothing was sent)."
    end

    needs_waiver = SendPendingGuardianInvitesJob.participant_events_needing_waivers(event)
    needs_invite = SendPendingGuardianInvitesJob.gpes_needing_invites(event)

    # Unopened invites still inside their validity window, which the job leaves
    # alone. Snapshot ids before the job runs so its re-sends (which refresh
    # invite_token_sent_at) can't land in this bucket and double-send.
    resend = GuardianParticipantEvent
      .joins(:participant_event)
      .where(participant_events: { event_id: event.id, status: :awaiting_guardian })
      .where(accepted_at: nil)
      .where(invite_token_sent_at: GuardianParticipantEvent::INVITE_VALIDITY.ago..)
      .where(invite_token_sent_at: ...sent_before)
    resend_ids = resend.pluck(:id)

    puts "#{event.name} (apply=#{apply}):"
    puts "  #{needs_waiver.count} submitted participants missing a signable waiver"
    needs_waiver.includes(:participant).find_each do |pe|
      puts "    - #{pe.participant.email} (#{pe.status})"
    end
    puts "  #{needs_invite.count} guardians never invited or expired unopened"
    needs_invite.includes(:guardian).find_each do |gpe|
      puts "    - #{gpe.guardian.email} (sent: #{gpe.invite_token_sent_at&.to_date || 'never'})"
    end
    puts "  #{resend_ids.size} unopened invites to re-send (sent before #{sent_before})"
    resend.includes(:guardian).find_each do |gpe|
      puts "    - #{gpe.guardian.email} (sent: #{gpe.invite_token_sent_at})"
    end

    unless apply
      puts "Dry run — set APPLY=1 to enqueue."
      exit
    end

    SendPendingGuardianInvitesJob.perform_now(event.id)

    GuardianParticipantEvent.where(id: resend_ids).find_each do |gpe|
      GuardianMailer.invitation(guardian_participant_event: gpe).deliver_later
      puts "  re-sent invite to #{gpe.guardian.email}"
    end

    puts "Done."
  end
end
