class AddFailureTrackingToAirtableSync < ActiveRecord::Migration[8.1]
  def change
    # Transient failures (rate limits, 5xx, timeouts) no longer pause the sync,
    # so count the failed runs in a row to know when to tell someone.
    add_column :events, :airtable_sync_failures, :integer, default: 0, null: false
    # When the current streak began. Measuring from the last good sync instead
    # would alert on the first blip after a long pause is lifted.
    add_column :events, :airtable_sync_failing_since, :datetime
    # When that streak was reported, so it's reported once rather than every run.
    add_column :events, :airtable_sync_alerted_at, :datetime
  end
end
