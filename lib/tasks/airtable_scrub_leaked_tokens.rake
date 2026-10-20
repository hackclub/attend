namespace :airtable do
  # Airtable personal access tokens used to live in events.config, so every
  # PaperTrail version and admin audit log of an event copied them in
  # plaintext. They now live in the encrypted events.airtable_api_key column
  # (migration 20261020170000). Run this once that deploy has fully rolled out:
  # old pods still read config until then.
  #
  #   rails airtable:scrub_leaked_tokens           # dry run, counts only
  #   APPLY=1 rails airtable:scrub_leaked_tokens   # write
  desc "Move Airtable tokens out of events.config and redact them from versions and audit logs (dry run unless APPLY=1)"
  task scrub_leaked_tokens: :environment do
    apply = ENV["APPLY"] == "1"
    counts = Hash.new(0)

    Event.where("config ? 'airtable_api_key'").find_each do |event|
      legacy = event.config["airtable_api_key"].to_s.strip.presence
      counts[:events] += 1
      next unless apply

      # A token saved through an old pod mid-rollout never reached the column.
      event.update_columns(airtable_api_key: legacy) if legacy && event.airtable_api_key.blank?
      event.update_columns(config: event.config.except("airtable_api_key"))
    end

    versions = PaperTrail::Version.where(item_type: "Event")
      .where("object LIKE '%airtable_api_key%' OR object_changes LIKE '%airtable_api_key%'")
    versions.find_each do |version|
      object = Airtable::TokenScrubber.scrub_serialized(version.object)
      object_changes = Airtable::TokenScrubber.scrub_serialized(version.object_changes)
      next if object == version.object && object_changes == version.object_changes

      counts[:versions] += 1
      version.update_columns(object: object, object_changes: object_changes) if apply
    end

    audit_logs = AuditLog.where("changed_fields::text LIKE '%airtable_api_key%' OR metadata::text LIKE '%airtable_api_key%'")
    audit_logs.find_each do |log|
      changed_fields = Airtable::TokenScrubber.scrub_value(log.changed_fields)
      metadata = Airtable::TokenScrubber.scrub_value(log.metadata)
      next if changed_fields == log.changed_fields && metadata == log.metadata

      counts[:audit_logs] += 1
      # AuditLog is read-only once written, and should stay that way; taking a
      # leaked secret out is the one edit worth going around it for.
      AuditLog.where(id: log.id).update_all(changed_fields: changed_fields, metadata: metadata) if apply
    end

    # Re-read everything that mentions the key and prove nothing live is left.
    if apply
      leftover = versions.reload.count do |version|
        Airtable::TokenScrubber.serialized_leaks?(version.object) ||
          Airtable::TokenScrubber.serialized_leaks?(version.object_changes)
      end
      leftover += audit_logs.reload.count do |log|
        Airtable::TokenScrubber.leaks?(log.changed_fields) || Airtable::TokenScrubber.leaks?(log.metadata)
      end
      leftover += Event.where("config ? 'airtable_api_key'").count
      abort "#{leftover} rows still hold an Airtable token — investigate before trusting this scrub." if leftover.positive?
    end

    puts "Events with a token in config: #{counts[:events]}"
    puts "Event versions holding a token: #{counts[:versions]}"
    puts "Audit logs holding a token: #{counts[:audit_logs]}"
    puts apply ? "Scrubbed, and verified nothing is left." : "Dry run — re-run with APPLY=1 to write changes."
  end
end
