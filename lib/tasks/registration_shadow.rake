namespace :registration do
  desc <<~DESC
    Read-only report of where the status column differs from the status
    Registration::Requirements says it should hold. This is the backlog the
    state machine will close.

    Split by whether the event is upcoming, under way or ended; ended events
    will be left as they are.

    Writes nothing.

    ENV:
      EVENT=<slug>   only this event (default: every event)
      VERBOSE=1      list the registration ids behind each count
  DESC
  task shadow: :environment do
    verbose = ENV["VERBOSE"] == "1"
    now = Time.current

    scope = ParticipantEvent.includes(
      :consents, :travel_inbound, :travel_outbound, :accommodation, :medical, :dietary,
      :accessibility, :safeguarding_info, :emergency_contacts, :participant,
      { event: :custom_documents }, guardian_participant_events: :emergency_contacts
    )
    scope = scope.where(event: Event.find_by!(slug: ENV.fetch("EVENT"))) if ENV["EVENT"].present?

    timing = lambda do |event|
      if event.ends_at.present? && event.ends_at < now then "ended"
      elsif event.starts_at.present? && event.starts_at <= now then "under way"
      else "upcoming"
      end
    end

    total = 0
    drift = Hash.new { |h, k| h[k] = [] }

    scope.find_each do |pe|
      total += 1
      requirements = pe.registration_requirements
      expected = requirements.computed_stage(now: now)
      next if expected == pe.status

      drift[[ timing.call(pe.event), pe.event.slug, pe.status, expected, requirements.blocking&.key ]] << pe.id
    end

    puts "#{total} registrations checked."
    drifted = drift.values.sum(&:size)
    puts "Status drift: #{drifted}"
    [ "upcoming", "under way", "ended" ].each do |bucket|
      rows = drift.select { |key, _| key.first == bucket }
      next if rows.empty?

      puts "  #{bucket} (#{rows.values.sum(&:size)})#{' — will be left as they are' if bucket == 'ended'}:"
      rows.sort_by { |key, ids| [ key[1], -ids.size ] }.each do |(_, slug, from, to, blocking), ids|
        stuck_on = blocking ? ", stuck on #{blocking}" : ""
        puts "    #{slug}: #{from} -> #{to}#{stuck_on} (#{ids.size})"
        ids.each { |id| puts "      #{id}" } if verbose
      end
    end
  end
end
