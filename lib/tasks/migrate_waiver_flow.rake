namespace :waivers do
  desc "Migrate existing minor waivers to teen-first signing flow"
  task migrate_to_teen_first: :environment do
    puts "Finding minor waivers that need migration..."

    # Find waivers that are either:
    # 1. pending_on: "guardian" (old flow, guardian signs first)
    # 2. pending with no pending_on and no docuseal slug (never sent to DocuSeal)
    affected_consents = Consent.waiver
      .joins(participant_event: :participant)
      .where.not(status: %w[signed voided])
      .where(
        "consents.pending_on = ? OR (consents.status = ? AND consents.docuseal_participant_slug IS NULL)",
        "guardian",
        "pending"
      )
      .includes(participant_event: [ :participant, :guardian_participant_events ])

    if affected_consents.empty?
      puts "No waivers need migration."
      exit
    end

    puts "Found #{affected_consents.count} waiver(s) to migrate."
    puts ""

    affected_consents.find_each do |consent|
      client = Docuseal::Client.for(consent)
      participant_event = consent.participant_event
      participant = participant_event&.participant
      guardian_participant_event = consent.guardian_participant_event || participant_event.guardian_participant_events.first

      unless participant && guardian_participant_event
        puts "  Skipping consent #{consent.id}: missing participant or guardian"
        next
      end

      puts "Processing consent #{consent.id} for #{participant.full_name}..."

      begin
        if consent.docuseal_envelope_id.present?
          puts "  Archiving old DocuSeal submission #{consent.docuseal_envelope_id}..."
          client.archive_submission(consent.docuseal_envelope_id)
        end
      rescue Docuseal::NotFoundError
        puts "  DocuSeal submission already archived or not found, continuing..."
      rescue Docuseal::Error => e
        puts "  Warning: Could not archive DocuSeal submission: #{e.message}"
      end

      consent.update!(
        status: :pending,
        docuseal_envelope_id: nil,
        docuseal_guardian_slug: nil,
        docuseal_participant_slug: nil,
        pending_on: nil,
        sent_at: nil,
        guardian_signed_at: nil,
        participant_signed_at: nil
      )

      puts "  Creating new waiver with teen-first order..."
      DocusealJobs::CreateMinorWaiverJob.perform_now(consent.id)

      consent.reload
      if consent.sent? && consent.docuseal_participant_slug.present?
        puts "  ✓ Waiver created successfully"
        puts "  ✓ Email sent to teen at #{participant.email}"
      else
        puts "  ✗ Waiver creation may have failed, please check"
      end

      puts ""
    end

    puts "Migration complete!"
    puts ""
    puts "Summary:"
    puts "- #{affected_consents.count} waiver(s) processed"
    puts "- Teens have been emailed with their signing links"
    puts "- Once teens sign, guardians will receive their signing invitation automatically"
  end

  desc "Preview which waivers would be migrated (dry run)"
  task preview_migration: :environment do
    puts "Finding minor waivers that need migration..."

    affected_consents = Consent.waiver
      .joins(participant_event: :participant)
      .where.not(status: %w[signed voided])
      .where(
        "consents.pending_on = ? OR (consents.status = ? AND consents.docuseal_participant_slug IS NULL)",
        "guardian",
        "pending"
      )
      .includes(participant_event: [ :participant, :event, guardian_participant_events: :guardian ])

    if affected_consents.empty?
      puts "No waivers need migration."
      exit
    end

    puts "Found #{affected_consents.count} waiver(s) that would be migrated:"
    puts ""

    affected_consents.find_each do |consent|
      participant_event = consent.participant_event
      participant = participant_event&.participant
      event = participant_event&.event
      guardian = consent.guardian_participant_event&.guardian ||
                 participant_event.guardian_participant_events.first&.guardian

      puts "- Consent ID: #{consent.id}"
      puts "  Event: #{event&.name}"
      puts "  Teen: #{participant&.full_name} (#{participant&.email})"
      puts "  Guardian: #{guardian&.full_name} (#{guardian&.email})"
      puts "  Status: #{consent.status}, pending_on: #{consent.pending_on}"
      puts "  DocuSeal ID: #{consent.docuseal_envelope_id}"
      puts ""
    end

    puts "Run 'rails waivers:migrate_to_teen_first' to perform the migration."
  end
end
