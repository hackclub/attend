namespace :airtable do
  desc "Report which events' Airtable sync config still resolves (read-only)"
  task diagnose: :environment do
    events = Event.with_airtable_sync_configured.includes(:airtable_connection)

    if events.empty?
      puts "No events have Airtable sync configured."
      exit
    end

    events.each do |event|
      last_sync = event.airtable_synced_at ? "#{time_ago(event.airtable_synced_at)} ago" : "never"
      puts "\n#{event.slug} (#{event.id})"
      puts "  base=#{event.airtable_base_id} table=#{event.airtable_sync_table_id} source=#{event.airtable_sync_source_id}"
      puts "  auth=#{event.airtable_connection ? "oauth (#{event.airtable_connection.account_label})" : 'personal access token'}"
      puts "  last successful sync: #{last_sync}#{event.airtable_sync_stale? ? '  [STALE]' : ''}"
      puts "  #{probe(event)}"
    end

    puts "\nA table that reads OK while SyncAllJob still 404s means the Sync Source ID is the stale one —"
    puts "the sync endpoint is the only way to check it, and there is no read-only probe for it."
  end

  # Reads one record through the same token/base/table the sync uses, so a 404
  # here rules the table (or the token's visibility of the base) in or out.
  # For an OAuth connection this may refresh the access token, as a sync would.
  def probe(event)
    client = Airtable::Client.for_event(event)
    if event.airtable_sync_via_records?
      # Attend creates its own table on first sync, so check the base.
      tables = client.list_tables.fetch("tables", [])
      ours = tables.find { |t| t["id"] == event.airtable_sync_table_id || t["name"] == Airtable::RecordsSync::TABLE_NAME }
      return "base reads OK — #{ours ? "Attend's table is #{ours['id']}" : 'no Attend table yet (the next sync creates it)'}"
    end

    client.list_records(event.airtable_sync_table_id, max_records: 1)
    "table reads OK — token, base and table all resolve"
  rescue Airtable::AuthenticationError => e
    "401 — the token is invalid or revoked (#{e.message})"
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
