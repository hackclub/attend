namespace :participants do
  desc "Report participants sharing an email address. APPLY=1 merges the unambiguous ones; " \
       "EMAILS=a@b.com,c@d.com merges exactly that reviewed list, flags and all"
  task deduplicate: :environment do
    apply = ENV["APPLY"] == "1"
    requested = ENV["EMAILS"]&.split(",")
    scan = DuplicateParticipantScan.new(emails: requested)
    groups = scan.groups

    puts apply ? "MODE: APPLY — merges will be written" : "MODE: dry run (re-run with APPLY=1 to merge)"
    puts "Addresses with more than one participant row: #{groups.size}"
    if scan.missing_emails.any?
      puts "Not duplicated (already merged, or mistyped): #{scan.missing_emails.join(', ')}"
    end
    if groups.empty?
      puts "Nothing to do."
      next
    end

    # Without an explicit list, only unambiguous groups are merged: a shared
    # address alone doesn't prove a shared identity, and the flagged cases are
    # the ones where merging the wrong pair would fuse two people's medical and
    # waiver data. Reviewed groups go through EMAILS=.
    reviewed = requested.present?
    merged_rows = 0
    skipped = []
    failures = []
    participants_before = Participant.count
    events_before = ParticipantEvent.count

    groups.each do |group|
      puts "\n#{'=' * 70}\n#{group.email}"
      group.rows.each do |row|
        events = row.participant_events.includes(:event).map { |pe| "#{pe.event.slug}:#{pe.status}" }
        marker = row == group.primary ? "keep" : "dup "
        puts "  #{marker} #{row.id} #{[ row.legal_first_name, row.legal_last_name ].join(' ').squish.inspect} " \
             "dob=#{row.date_of_birth || '—'} account=#{row.user&.email || 'none'}"
        puts "       registrations=#{events.presence&.join(', ') || 'none'}" \
             "#{row.public_profile_enabled? ? " public_profile=/p/#{row.public_profile_slug}" : ''}"
      end
      puts "  FLAGS: #{group.flags.join(', ')}" if group.flags.any?

      if apply && !group.safe? && !reviewed
        skipped << group
        puts "  SKIPPED — needs review. Merge it with: " \
             "bin/rails participants:deduplicate APPLY=1 EMAILS=#{group.email}"
        next
      end

      group.duplicates.each do |duplicate|
        service = ParticipantMergeService.new(primary: group.primary, duplicate: duplicate)
        actions = apply ? service.merge! : service.preview
        puts "  #{apply ? 'MERGED' : 'would merge'} #{duplicate.id}:"
        actions.each { |action| puts "        - #{action}" }
        puts "        - empty row, deleted with nothing to transfer" if actions.empty?
        merged_rows += 1
      rescue ActiveRecord::RecordInvalid, ParticipantMergeService::Error => e
        # Each merge is its own transaction, so a failure here leaves that pair
        # untouched and the rest of the run still lands.
        puts "  FAILED #{duplicate.id} — nothing changed for this pair: #{e.class}: #{e.message}"
        failures << [ group.email, duplicate.id, "#{e.class}: #{e.message}" ]
      end
    end

    puts "\n#{'=' * 70}"
    puts "#{apply ? 'Merged' : 'Would merge'} #{merged_rows} duplicate row(s)"
    if apply
      puts "Participants: #{participants_before} -> #{Participant.count}"
      puts "Registrations: #{events_before} -> #{ParticipantEvent.count}"
      puts "Addresses still duplicated: #{DuplicateParticipantScan.new.duplicate_emails.size}"
    end
    if skipped.any?
      puts "\nSkipped, needing review (#{skipped.size}):"
      skipped.each { |group| puts "  #{group.email} — #{group.flags.join(', ')}" }
      puts "Review them, then re-run with EMAILS=#{skipped.map(&:email).join(',')}"
    end
    if failures.any?
      puts "\nFailed (#{failures.size}) — nothing was written for these:"
      failures.each { |email, id, message| puts "  #{email} #{id}: #{message}" }
    end
  end
end
