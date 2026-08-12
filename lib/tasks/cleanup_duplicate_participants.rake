namespace :participants do
  desc "Find and merge duplicate participants by email"
  task deduplicate: :environment do
    puts "Finding duplicate participants by email..."

    duplicates = Participant
      .select("LOWER(email) as lower_email")
      .group("LOWER(email)")
      .having("COUNT(*) > 1")
      .pluck(Arel.sql("LOWER(email)"))

    if duplicates.empty?
      puts "No duplicate participants found."
      exit
    end

    puts "Found #{duplicates.count} emails with duplicate participants.\n\n"

    duplicates.each do |email|
      participants = Participant.where("LOWER(email) = ?", email).order(:created_at).to_a
      puts "=" * 60
      puts "Email: #{email}"
      puts "Found #{participants.count} duplicates:"

      participants.each_with_index do |p, i|
        pe_count = p.participant_events.count
        status = p.participant_events.map { |pe| "#{pe.event.name}: #{pe.status}" }.join(", ")
        has_user = p.user_id.present? ? "linked to user #{p.user_id}" : "no user"
        puts "  #{i + 1}. ID: #{p.id} | #{p.full_name} | #{pe_count} events | #{has_user}"
        puts "     Status: #{status}" if status.present?
        puts "     Created: #{p.created_at}"
      end

      # Determine the "primary" participant to keep:
      # Prefer one linked to a user, then one with most participant_events, then most recent
      primary = participants.find { |p| p.user_id.present? } ||
                participants.max_by { |p| [ p.participant_events.count, p.created_at ] }

      duplicates_to_merge = participants - [ primary ]

      puts "\n  → Keeping: #{primary.id} (#{primary.full_name})"
      puts "  → Merging #{duplicates_to_merge.count} duplicate(s) into primary\n\n"

      ActiveRecord::Base.transaction do
        duplicates_to_merge.each do |dup|
          ParticipantMergeService.new(primary: primary, duplicate: dup).merge!.each do |action|
            puts "    #{action}"
          end
          puts "    Deleted duplicate #{dup.id}"
        end
      end
    end

    puts "\n" + "=" * 60
    puts "Deduplication complete!"
  end
end
