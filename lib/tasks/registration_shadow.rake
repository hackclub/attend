namespace :registration do
  desc <<~DESC
    Read-only report comparing Registration::Requirements with what's stored.

    Two checks per registration:

      parity  Requirements#display_status and #progress against the model's
              own #display_status and #onboarding_progress. These should never
              differ; a non-zero count means the port is wrong.

      drift   the status column against the status Requirements says it
              should hold. This is the backlog the state machine will close.
              Split by whether the event is upcoming, under way or ended;
              ended events will be left as they are.

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
    parity = []
    drift = Hash.new { |h, k| h[k] = [] }

    scope.find_each do |pe|
      total += 1
      requirements = Registration::Requirements.new(pe)

      if requirements.display_status != pe.display_status || requirements.progress != pe.onboarding_progress
        parity << pe.id
      end

      expected = requirements.computed_stage(now: now)
      next if expected == pe.status

      drift[[ timing.call(pe.event), pe.event.slug, pe.status, expected, requirements.blocking&.key ]] << pe.id
    end

    puts "#{total} registrations checked."
    puts
    puts "Parity mismatches: #{parity.size}#{' (expected 0)' if parity.any?}"
    parity.each { |id| puts "  #{id}" } if verbose

    drifted = drift.values.sum(&:size)
    puts
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
