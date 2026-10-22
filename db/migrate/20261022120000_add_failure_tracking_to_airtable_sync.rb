class AddFailureTrackingToAirtableSync < ActiveRecord::Migration[8.1]
  def change
    # Transient failures (rate limits, 5xx, timeouts) no longer pause the sync,
    # so count the failed runs in a row to know when to tell someone.
    add_column :events, :airtable_sync_failures, :integer, default: 0, null: false
    # When that streak was reported, so it's reported once rather than every run.
    add_column :events, :airtable_sync_alerted_at, :datetime
  end
end
