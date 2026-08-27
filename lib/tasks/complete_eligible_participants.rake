namespace :backfill do
  desc "Mark participant_events complete that already satisfy every requirement (dry run unless APPLY=1)"
  task complete_eligible_participants: :environment do
    apply = ENV["APPLY"] == "1"
    count = 0
    skipped = 0

    # Guardian completion used to be marked off a stale association read, so a
    # participant whose guardian finished last never advanced past in_progress
    # even with everything signed. Anything still eligible here is that bug's
    # backlog; `mark_complete_if_eligible!` re-checks every gate, so nothing
    # incomplete slips through.
    ParticipantEvent.where.not(status: [ :complete, :withdrawn, :rejected ])
      .includes(:participant, :event, :consents, :guardian_participant_events)
      .find_each do |participant_event|
        next unless participant_event.eligible_for_completion?

        count += 1
        label = "#{participant_event.id} (#{participant_event.event&.slug} / #{participant_event.participant&.email})"
        puts "#{label}: #{participant_event.status} -> complete"
        next unless apply

        skipped += 1 unless participant_event.mark_complete_if_eligible!
      end

    puts "\n#{apply ? "Completed" : "Would complete"} #{count} participant event(s)."
    puts "#{skipped} were no longer eligible when written." if skipped.positive?
    puts "Dry run — re-run with APPLY=1 to write changes." unless apply
  end
end
