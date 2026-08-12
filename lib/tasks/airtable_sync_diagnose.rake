namespace :airtable do
  desc "Report which events' Airtable sync config still resolves (read-only)"
  task diagnose: :environment do
    events = Event.where.not(airtable_sync_source_id: [ nil, "" ])
                  .where.not(airtable_sync_table_id: [ nil, "" ])
                  .where("config->>'airtable_api_key' IS NOT NULL")
                  .where("config->>'airtable_base_id' IS NOT NULL")

    if events.empty?
      puts "No events have Airtable sync configured."
      exit
    end

    events.each do |event|
      last_sync = event.airtable_synced_at ? "#{time_ago(event.airtable_synced_at)} ago" : "never"
      puts "\n#{event.slug} (#{event.id})"
      puts "  base=#{event.airtable_base_id} table=#{event.airtable_sync_table_id} source=#{event.airtable_sync_source_id}"
      puts "  last successful sync: #{last_sync}#{event.airtable_sync_stale? ? '  [STALE]' : ''}"
      puts "  #{probe(event)}"
    end

    puts "\nA table that reads OK while SyncAllJob still 404s means the Sync Source ID is the stale one —"
    puts "the sync endpoint is the only way to check it, and there is no read-only probe for it."
  end

  # Reads one record through the same token/base/table the sync uses, so a 404
  # here rules the table (or the token's visibility of the base) in or out.
  def probe(event)
    client = Airtable::Client.new(api_key: event.airtable_api_key, base_id: event.airtable_base_id)
    client.list_records(event.airtable_sync_table_id, max_records: 1)
    "table reads OK — token, base and table all resolve"
  rescue Airtable::AuthenticationError
    "401 — the personal access token is invalid or revoked"
  rescue Airtable::NotFoundError
    # Airtable answers 404 (not 403) for a base the token cannot see, so a
    # revoked or rescoped token is indistinguishable from a deleted base here.
    "404 — the base or table is gone, or the token can no longer see it"
  rescue Airtable::Error => e
    "#{e.status || 'error'} — #{e.message}"
  end

  def time_ago(time)
    ActionController::Base.helpers.time_ago_in_words(time)
  end
end
