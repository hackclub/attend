namespace :identity do
  desc "Strip and downcase stored participant, guardian and emergency contact emails (dry run unless APPLY=1)"
  task normalize_emails: :environment do
    apply = ENV["APPLY"] == "1"
    puts apply ? "MODE: APPLY" : "MODE: dry run (re-run with APPLY=1 to write)"

    # Counts only, here and below: this output lands in terminals and logs.
    normalised = "LOWER(BTRIM(email, E' \\t\\r\\n'))"
    [ Participant, Guardian, EmergencyContact ].each do |model|
      table = model.table_name
      stale = model.where("email IS NOT NULL AND email <> #{normalised}")
      total = stale.count

      # Rows that, once rewritten, hold exactly the same address as another
      # row. They already matched case-insensitively, so nothing new breaks
      # and nothing here can fail on them (no unique index on these columns);
      # they are the same-address groups identity:backfill sorts out.
      sharing = stale.where(<<~SQL.squish).count
        EXISTS (SELECT 1 FROM #{table} other
                WHERE other.id <> #{table}.id
                  AND LOWER(BTRIM(other.email, E' \\t\\r\\n')) = LOWER(BTRIM(#{table}.email, E' \\t\\r\\n')))
      SQL

      written = 0
      if apply
        stale.in_batches(of: 500) do |batch|
          # update_all: legacy rows must not be held up by validations, and a
          # case-only rewrite should not fan out callbacks or write versions.
          written += batch.update_all("email = #{normalised}")
        end
      end

      puts "\n#{table}"
      puts "  #{apply ? 'normalised' : 'would normalise'}: #{apply ? written : total}"
      puts "  of those, sharing their address with another row: #{sharing}"
    end

    # The model validations stop a participant and their own guardian holding
    # one address, but only when the email changes. Report what already sits
    # in the data so it isn't a surprise later; this task does not touch it.
    collisions = GuardianParticipantEvent.joins(:guardian, participant_event: :participant)
      .where("LOWER(BTRIM(guardians.email, E' \\t\\r\\n')) = LOWER(BTRIM(participants.email, E' \\t\\r\\n'))")
      .distinct.count(:guardian_id)
    puts "\nguardians sharing an address with their own participant (not changed): #{collisions}"
  end

  desc "Join users, participants and guardians up to people, with their emails and phones (dry run unless APPLY=1)"
  task backfill: :environment do
    apply = ENV["APPLY"] == "1"
    batch_size = ENV.fetch("BATCH_SIZE", 500).to_i
    puts apply ? "MODE: APPLY" : "MODE: dry run (re-run with APPLY=1 to write)"

    report = Identity::Backfill.new(apply: apply, batch_size: batch_size).call

    verb = apply ? "" : "would be "
    headings = { mechanical: "#{verb}joined or created mechanically", needs_review: "left for review", skipped: "skipped" }
    report.each do |section, kinds|
      puts "\n#{section.to_s.humanize}"
      headings.each do |kind, heading|
        next if kinds[kind].blank?

        puts "  #{heading}:"
        kinds[kind].each { |bucket, total| puts "    #{bucket.to_s.humanize(capitalize: false)}: #{total}" }
      end
    end

    puts "\nOpen identity reviews on file: #{IdentityReview.open.count}"
    puts "Dry run: nothing was written." unless apply
  end
end
