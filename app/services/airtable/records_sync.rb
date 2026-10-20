module Airtable
  # Mirrors an event's participants into an ordinary Airtable table through the
  # records API, for events connected with OAuth. The Sync API that pasted
  # personal access tokens use only accepts those tokens, so a connected event
  # can't use it.
  #
  # Each event owns one table, named after it, found by its stored id or name
  # and created on first sync. Two events can share a base but never a table:
  # one event's sync deletes rows the other needs. Each run adds any missing
  # columns, writes only the rows whose cells differ from Attend's, and deletes
  # rows for this event's departed participants. Columns and rows organisers
  # add themselves are left alone; edits to Attend's columns are overwritten.
  class RecordsSync
    TABLE_NAME_PREFIX = "Attend Participants".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    KEY_FIELD = SyncService::SYNC_COLUMNS.first
    FIELD_TYPE = "singleLineText".freeze
    BATCH_SIZE = 10
    # Airtable allows 5 requests a second per base.
    REQUEST_INTERVAL = 0.25

    Result = Data.define(:written, :deleted, :unchanged)

    def initialize(event, client, request_interval: REQUEST_INTERVAL)
      @event = event
      @client = client
      @request_interval = request_interval
      @last_request_at = nil
    end

    def self.table_name_for(event)
      "#{TABLE_NAME_PREFIX} (#{event.slug})"
    end

    # rows: { participant_event_id => { column => string or nil } }
    def call(rows)
      rows = rows.transform_keys(&:to_s)
      table_id = resolve_table
      existing, duplicate_ids = existing_records(table_id)

      stale_ids = existing.slice(*departed_keys(existing.keys - rows.keys)).values.pluck("id") + duplicate_ids
      # Duplicates go first: an upsert matching two rows is rejected.
      stale_ids.each_slice(BATCH_SIZE) { |ids| request { @client.delete_records(table_id, ids) } }

      changed = rows.reject { |id, fields| existing[id] && same_cells?(existing[id]["fields"], fields) }
      changed.values.each_slice(BATCH_SIZE) do |batch|
        request { @client.upsert_records(table_id, batch, merge_on: KEY_FIELD) }
      end

      Result.new(written: changed.size, deleted: stale_ids.size, unchanged: rows.size - changed.size)
    end

    private

    def resolve_table
      tables = request { @client.list_tables }.fetch("tables", [])
      # Never adopt a table another event already syncs into.
      claimed = Event.where.not(id: @event.id).where(airtable_sync_table_id: tables.pluck("id")).pluck(:airtable_sync_table_id)
      tables = tables.reject { |t| claimed.include?(t["id"]) }

      table = tables.find { |t| t["id"] == @event.airtable_sync_table_id } ||
        tables.find { |t| t["name"] == self.class.table_name_for(@event) }
      table ||= request do
        # The first field becomes the table's primary field.
        @client.create_table(self.class.table_name_for(@event), SyncService::SYNC_COLUMNS.map { |name| { name: name, type: FIELD_TYPE } })
      end

      present = Array(table["fields"]).pluck("name")
      (SyncService::SYNC_COLUMNS - present).each do |name|
        request { @client.create_field(table["id"], name, FIELD_TYPE) }
      end

      @event.update_columns(airtable_sync_table_id: table["id"]) if @event.airtable_sync_table_id != table["id"]
      table["id"]
    end

    def existing_records(table_id)
      by_key = {}
      duplicate_ids = []
      offset = nil

      loop do
        options = { fields: SyncService::SYNC_COLUMNS, page_size: 100 }
        options[:offset] = offset if offset.present?
        page = request { @client.list_records(table_id, options) }

        Array(page["records"]).each do |record|
          key = record.dig("fields", KEY_FIELD).to_s.strip
          next if key.blank?

          by_key.key?(key) ? duplicate_ids << record["id"] : by_key[key] = record
        end

        offset = page["offset"]
        break if offset.blank?
      end

      [ by_key, duplicate_ids ]
    end

    # Rows Attend may delete: keys that are participant event ids and don't
    # belong to another event (so a departed participant of this one). A key
    # an organiser typed in, or another event's row pasted across, stays.
    def departed_keys(keys)
      ids = keys.grep(UUID)
      ids - ParticipantEvent.where(id: ids).where.not(event_id: @event.id).pluck(:id)
    end

    # Airtable leaves empty cells out of the response entirely.
    def same_cells?(airtable_fields, fields)
      fields.all? { |column, value| airtable_fields[column].to_s == value.to_s }
    end

    def request
      if @last_request_at && @request_interval.positive?
        wait = @request_interval - (monotonic_now - @last_request_at)
        sleep(wait) if wait.positive?
      end
      yield
    ensure
      @last_request_at = monotonic_now
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
