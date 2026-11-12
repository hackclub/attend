namespace :backfill do
  # ParticipantEvent#accept_invitations stamps an invitation accepted once its
  # participant starts registering. Before that hook, only clicking the link
  # did, so anyone who started from their dashboard — or was re-invited by
  # staff after finishing — still shows on the pending invitations tab. This
  # accepts those. Prints counts only, so the output is safe to paste anywhere.
  desc "Accept invitations whose participant has already started registering (dry run unless APPLY=1)"
  task started_invitations: :environment do
    apply = ENV["APPLY"] == "1"

    stale = Invitation.where(accepted_at: nil).where(<<~SQL, ParticipantEvent::STARTED_STATUSES)
      EXISTS (
        SELECT 1 FROM participant_events pe
        JOIN participants p ON p.id = pe.participant_id
        WHERE pe.event_id = invitations.event_id
          AND LOWER(p.email) = LOWER(invitations.email)
          AND pe.status IN (?)
      )
    SQL

    stale.group(:event_id).count.sort_by { |_, n| -n }.each do |event_id, n|
      puts "event #{event_id}: #{n}"
    end

    total = stale.count
    stale.find_each(&:accept!) if apply

    puts "\n#{apply ? "Accepted" : "Would accept"} #{total} invitation(s)."
    puts "Dry run — re-run with APPLY=1 to write changes." unless apply
  end
end
