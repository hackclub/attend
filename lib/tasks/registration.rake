namespace :registration do
  desc <<~DESC
    Bring stored statuses in line with what each registration still needs.

    Every change that affects a requirement already re-syncs the status, so
    this is for the backlog from before that existed (the dry run lists what
    it will change) and for repairing anything the nightly
    RegistrationDriftCheckJob reports. Events that have ended are left alone.

    ENV:
      EVENT=<slug>   only this event (default: every event that hasn't ended)
      APPLY=1        actually write (default: dry run)
      NOTIFY=1       send the usual emails, e.g. the confirmation to someone
                     this completes (default: silent)
  DESC
  task sync: :environment do
    apply = ENV["APPLY"] == "1"
    notify = ENV["NOTIFY"] == "1"

    scope = ParticipantEvent.all
    scope = scope.where(event: Event.find_by!(slug: ENV.fetch("EVENT"))) if ENV["EVENT"].present?

    drifted = RegistrationDriftCheckJob.drifted(scope)
    moves = drifted.group_by { |pe| [ pe.event.slug, pe.status, pe.registration_requirements.stage ] }

    puts "#{drifted.size} registration#{'s' unless drifted.size == 1} to sync (apply=#{apply}, notify=#{notify}):"
    moves.sort_by { |(slug, _, _), rows| [ slug, -rows.size ] }.each do |(slug, from, to), rows|
      puts "  #{slug}: #{from} -> #{to} (#{rows.size})"
    end

    unless apply
      puts "Dry run. Set APPLY=1 to write."
      next
    end

    PaperTrail.request.whodunnit = "rake registration:sync"

    changed = drifted.count do |pe|
      ParticipantEvent.find(pe.id).sync_status!(cause: :backfill, actor: nil, notify: notify)
    end
    puts "Synced #{changed} of #{drifted.size}."
  end
end
