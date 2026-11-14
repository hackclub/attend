namespace :backfill do
  desc "Email participants whose registration is only waiting on their own submit (dry run unless APPLY=1)"
  task remind_unsubmitted_registrations: :environment do
    apply = ENV["APPLY"] == "1"
    count = 0

    # Registrations with every signature in (guardian included) but no code
    # of conduct, because the participant never hit submit. Before
    # ParticipantEvent#remind_to_submit_if_only_step_left nothing prompted
    # them, so these sat in_progress for good. Past events are left alone:
    # there's nothing left to register for.
    ParticipantEvent.joins(:event)
      .where(status: [ :in_progress, :awaiting_guardian ], code_of_conduct_accepted_at: nil, submission_reminder_sent_at: nil)
      .where("events.ends_at IS NULL OR events.ends_at > ?", Time.current)
      .includes(:participant, :event, :consents, :guardian_participant_events)
      .find_each do |participant_event|
        next unless participant_event.eligible_for_completion?(ignoring_submission: true)

        count += 1
        puts "#{participant_event.id} (#{participant_event.event.slug} / #{participant_event.participant&.email})"
        participant_event.remind_to_submit_if_only_step_left if apply
      end

    puts "\n#{apply ? "Reminded" : "Would remind"} #{count} participant(s)."
    puts "Dry run — re-run with APPLY=1 to send." unless apply
  end
end
